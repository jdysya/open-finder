import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import OpenFinderCore

final class AppDatabaseMigrationTests: XCTestCase {
    func testFreshAndIncrementalMigrations() throws {
        let freshURL = makeDatabaseURL()
        let incrementalURL = makeDatabaseURL()
        defer {
            removeDatabase(at: freshURL)
            removeDatabase(at: incrementalURL)
        }

        let fresh = try AppDatabase(url: freshURL)
        try fresh.databasePool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT schema_version FROM app_schema_metadata"), 2)
            XCTAssertEqual(Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")), expectedTables)
            for (table, requiredColumns) in expectedColumns {
                XCTAssertTrue(
                    try columns(in: table, db: db).isSuperset(of: requiredColumns),
                    "\(table) is missing required columns"
                )
            }
        }
        try fresh.databasePool.close()

        let firstVersion = AppDatabase.applicationMigrator(upToSchemaVersion: 1)
        let queue = try DatabaseQueue(path: incrementalURL.path)
        try firstVersion.migrate(queue)
        try queue.write { db in
            try insertTaskFixture(db)
        }
        try queue.close()

        let incremental = try AppDatabase(url: incrementalURL)
        try incremental.databasePool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT schema_version FROM app_schema_metadata"), 2)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT title FROM task_records WHERE task_id = ?", arguments: [taskID]), "preserved")
            XCTAssertTrue(try db.tableExists("artifact_records"))
            XCTAssertTrue(try db.tableExists("media_managed_tags"))
        }
        try incremental.databasePool.close()

        let reopened = try AppDatabase(url: incrementalURL)
        try reopened.databasePool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_records"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations"), 2)
        }
        try reopened.databasePool.close()
        print("migration_observable fresh=2 incremental=1->2 task_rows=1 repeat_open=stable")
    }

    func testSchemaConstraintsForeignKeysAndIndexes() throws {
        let url = makeDatabaseURL()
        defer { removeDatabase(at: url) }
        let appDatabase = try AppDatabase(url: url)

        try appDatabase.databasePool.write { db in
            try insertTaskFixture(db)
            let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(task_artifacts)")
            XCTAssertEqual(Set(foreignKeys.compactMap { $0["table"] as String? }), ["task_records", "artifact_records"])

            let indexes = Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'"
            ))
            XCTAssertTrue(indexes.isSuperset(of: [
                "idx_task_descriptors_queue_ordinal",
                "idx_task_records_status",
                "idx_task_logs_task_sequence",
                "idx_artifact_records_retention",
                "idx_task_artifacts_artifact",
                "idx_media_documents_task",
                "idx_media_tags_stable_media"
            ]))

            XCTAssertThrowsError(try db.execute(
                sql: "INSERT INTO task_logs (task_id, sequence, logged_at, level, message) VALUES (?, -1, 0, 'info', 'bad')",
                arguments: [taskID]
            ))
            XCTAssertThrowsError(try db.execute(
                sql: """
                    INSERT INTO artifact_records (
                        artifact_id, record_version, schema_id, state, relative_path, media_type,
                        byte_count, sha256, staged_at, reconciliation_state
                    ) VALUES ('bad', 1, 'mediaAnalysis.v1', 'committed', '../escape', 'text/plain',
                        -1, 'short', 0, 'stable')
                    """
            ))
            XCTAssertThrowsError(try db.execute(
                sql: "INSERT INTO task_artifacts (task_id, artifact_id, ordinal) VALUES (?, 'missing', 0)",
                arguments: [taskID]
            ))
        }
        try appDatabase.databasePool.close()
        print("schema_observable foreign_keys=2 required_indexes=7 malformed_rows=rejected")
    }

    func testFutureAndCorruptDatabasesFailReadOnlyAndPreserveBytes() throws {
        let futureURL = makeDatabaseURL()
        let corruptURL = makeDatabaseURL()
        defer {
            removeDatabase(at: futureURL)
            removeDatabase(at: corruptURL)
        }

        let futureQueue = try DatabaseQueue(path: futureURL.path)
        try futureQueue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('openfinder.999.future')")
        }
        try futureQueue.close()
        let futureBefore = try Data(contentsOf: futureURL)

        XCTAssertThrowsError(try AppDatabase(url: futureURL)) { error in
            XCTAssertEqual(error as? AppDatabaseError, .futureSchema)
        }
        XCTAssertEqual(try Data(contentsOf: futureURL), futureBefore)

        let corruptBytes = Data([0x4f, 0x70, 0x65, 0x6e, 0x46, 0x69, 0x6e, 0x64, 0xff, 0x00])
        try corruptBytes.write(to: corruptURL)
        XCTAssertThrowsError(try AppDatabase(url: corruptURL)) { error in
            XCTAssertEqual(error as? AppDatabaseError, .databaseValidationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes)
        print("failure_observable future_sha256=\(sha256(futureBefore)) corrupt_sha256=\(sha256(corruptBytes)) bytes_preserved=true")
    }

    func testDoesNotImportLegacyVideoAnalysisStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseLegacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("video-analysis-results.json")
        let legacyBytes = Data(#"{"taskID":"legacy","videos":[{"path":"/private/video.mp4"}]}"#.utf8)
        try legacyBytes.write(to: legacyURL)

        let appDatabase = try AppDatabase(url: root.appendingPathComponent("app.sqlite"))
        try appDatabase.databasePool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_analysis_documents"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_managed_tags"), 0)
        }
        try appDatabase.databasePool.close()
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyBytes)
        print("legacy_observable imported_documents=0 imported_tags=0 legacy_sha256=\(sha256(legacyBytes))")
    }

    private let taskID = "11111111-1111-1111-1111-111111111111"

    private var expectedTables: Set<String> {
        [
            "app_schema_metadata", "grdb_migrations", "task_descriptors", "task_records",
            "task_logs", "artifact_records", "task_artifacts", "media_analysis_documents",
            "media_managed_tags"
        ]
    }

    private var expectedColumns: [String: Set<String>] {
        [
            "task_descriptors": [
                "task_id", "schema_version", "handler_id", "payload_version",
                "redacted_payload", "root_task_id", "parent_task_id", "attempt",
                "resource_key", "idempotency_key", "queue_ordinal", "created_at"
            ],
            "task_records": [
                "task_id", "record_version", "kind_payload", "title", "status",
                "status_reason", "progress", "progress_detail", "created_at",
                "started_at", "finished_at", "effects_committed_at"
            ],
            "task_logs": ["task_id", "sequence", "logged_at", "level", "message"],
            "artifact_records": [
                "artifact_id", "record_version", "schema_id", "state", "relative_path",
                "media_type", "byte_count", "sha256", "retention_deadline",
                "reconciliation_state", "reconciliation_reason", "reconciled_at"
            ],
            "task_artifacts": ["task_id", "artifact_id", "ordinal", "linked_at"],
            "media_analysis_documents": [
                "document_id", "task_id", "schema_id", "schema_version", "payload",
                "retention_deadline", "reconciliation_state", "reconciliation_reason"
            ],
            "media_managed_tags": [
                "document_id", "stable_media_id", "source_path", "display_name",
                "tag_name", "ordinal", "managed_at", "reconciliation_state"
            ]
        ]
    }

    private func columns(in table: String, db: Database) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").compactMap {
            $0["name"] as String?
        })
    }

    private func insertTaskFixture(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO task_descriptors (
                    task_id, schema_version, handler_id, payload_version, redacted_payload,
                    root_task_id, attempt, queue_ordinal, created_at
                ) VALUES (?, 1, 'plugin.execute.v1', 1, X'7B7D', ?, 1, 7, 0)
                """,
            arguments: [taskID, taskID]
        )
        try db.execute(
            sql: """
                INSERT INTO task_records (
                    task_id, record_version, kind_payload, title, status, created_at,
                    input_summary, retry_count
                ) VALUES (?, 1, X'7B7D', 'preserved', 'queued', 0, '', 0)
                """,
            arguments: [taskID]
        )
    }

    private func makeDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseMigrationTests-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
