import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import OpenFinderCore

final class PersistenceRetentionTests: XCTestCase {
    func testThirtyDayRetentionAndMediaReferences() async throws {
        // Given
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 4_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let retained = UUID()
        let boundary = UUID()
        let expired = UUID()
        let live = UUID()
        let pinnedArtifact = UUID()
        let referencedArtifact = UUID()
        let expiredArtifact = UUID()
        try fixture.insertTask(retained, status: .succeeded, finishedAt: now.addingTimeInterval(-29 * day), ordinal: 1)
        try fixture.insertTask(boundary, status: .failed, finishedAt: now.addingTimeInterval(-30 * day), ordinal: 2)
        try fixture.insertTask(expired, status: .cancelled, finishedAt: now.addingTimeInterval(-31 * day), ordinal: 3)
        try fixture.insertTask(live, status: .running, finishedAt: nil, ordinal: 4)
        try fixture.insertArtifact(pinnedArtifact, taskID: boundary, finishedAt: now.addingTimeInterval(-30 * day))
        try fixture.insertArtifact(expiredArtifact, taskID: expired, finishedAt: now.addingTimeInterval(-31 * day))
        try fixture.insertArtifact(referencedArtifact, taskID: expired, finishedAt: now.addingTimeInterval(-31 * day), ordinal: 1)
        try fixture.insertMediaReference(documentID: UUID(), taskID: live, artifactID: referencedArtifact)
        let maintenance = PersistenceMaintenance(
            databasePool: fixture.database.databasePool,
            artifactRoot: fixture.artifactRoot,
            clock: { now }
        )

        // When
        let report = await maintenance.runAtStartup(pinnedArtifactIDs: [pinnedArtifact])

        // Then
        XCTAssertEqual(Set(report.removedTaskIDs), [boundary, expired])
        XCTAssertEqual(report.removedArtifactIDs, [expiredArtifact])
        XCTAssertTrue(try fixture.taskExists(retained))
        XCTAssertTrue(try fixture.taskExists(live))
        XCTAssertFalse(try fixture.taskExists(boundary))
        XCTAssertFalse(try fixture.taskExists(expired))
        XCTAssertTrue(try fixture.artifactExists(pinnedArtifact))
        XCTAssertTrue(try fixture.artifactExists(referencedArtifact))
        XCTAssertFalse(try fixture.artifactExists(expiredArtifact))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url(for: pinnedArtifact, taskID: boundary).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url(for: referencedArtifact, taskID: expired).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url(for: expiredArtifact, taskID: expired).path))
        print("retention_fixture removed_tasks=30d,31d retained=29d,live pinned=1 referenced=1")
    }

    func testCleanupFailureIsAuditedAndRetriedByPeriodicMaintenance() async throws {
        // Given
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 4_000_000)
        let taskID = UUID()
        let artifactID = UUID()
        try fixture.insertTask(
            taskID,
            status: .failed,
            finishedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            ordinal: 1
        )
        try fixture.insertArtifact(
            artifactID,
            taskID: taskID,
            finishedAt: now.addingTimeInterval(-31 * 24 * 60 * 60)
        )
        let artifactURL = fixture.url(for: artifactID, taskID: taskID)
        let fileManager = FailOnceFileManager(target: artifactURL)
        let maintenance = PersistenceMaintenance(
            databasePool: fixture.database.databasePool,
            artifactRoot: fixture.artifactRoot,
            fileManager: fileManager,
            clock: { now }
        )

        // When
        let first = await maintenance.runAtStartup()

        // Then
        XCTAssertTrue(first.issues.contains {
            $0.kind == .cleanupFailure && $0.artifactID == artifactID
        })
        XCTAssertTrue(try fixture.artifactExists(artifactID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path))
        guard let diagnostic = try fixture.artifactDiagnostic(artifactID) else {
            XCTFail("cleanup failure removed the durable artifact receipt")
            return
        }
        XCTAssertEqual(diagnostic.attempts, 1)
        XCTAssertNotNil(diagnostic.reason)

        // When
        let second = await maintenance.runPeriodically()

        // Then
        XCTAssertEqual(second.removedArtifactIDs, [artifactID])
        XCTAssertFalse(try fixture.artifactExists(artifactID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
        let pathHash = SHA256.hash(data: Data(artifactURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        print("cleanup_retry_fixture first_issue=1 durable_attempts=1 second_removed=1 path_sha256=\(pathHash)")
    }
}

final class PersistenceFixture {
    let root: URL
    let artifactRoot: URL
    let database: AppDatabase

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceRetention-\(UUID().uuidString)", isDirectory: true)
        artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        database = try AppDatabase(url: root.appendingPathComponent("app.sqlite"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func insertTask(_ id: UUID, status: TaskStatus, finishedAt: Date?, ordinal: Int) throws {
        try database.databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO task_descriptors (
                        task_id, schema_version, handler_id, payload_version, redacted_payload,
                        root_task_id, attempt, queue_ordinal, created_at
                    ) VALUES (?, 1, 'fixture', 1, X'7B7D', ?, 1, ?, ?)
                    """,
                arguments: [id.uuidString, id.uuidString, ordinal, finishedAt?.timeIntervalSince1970 ?? 1]
            )
            try db.execute(
                sql: """
                    INSERT INTO task_records (
                        task_id, record_version, kind_payload, title, status, created_at,
                        finished_at, input_summary, retry_count
                    ) VALUES (?, 1, X'7B7D', 'fixture', ?, ?, ?, '', 0)
                    """,
                arguments: [
                    id.uuidString, status.rawValue,
                    finishedAt?.timeIntervalSince1970 ?? 1,
                    finishedAt?.timeIntervalSince1970
                ]
            )
        }
    }

    func insertArtifact(
        _ id: UUID,
        taskID: UUID,
        finishedAt: Date,
        ordinal: Int = 0,
        linkToTask: Bool = true
    ) throws {
        let relativePath = "published/\(taskID.uuidString)/\(id.uuidString)/payload"
        let bytes = Data(id.uuidString.utf8)
        let destination = artifactRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: destination)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try database.databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO artifact_records (
                        artifact_id, record_version, schema_id, state, relative_path,
                        media_type, byte_count, sha256, staged_at, finished_at,
                        retention_deadline, reconciliation_state
                    ) VALUES (?, 1, 'mediaAnalysis.v1', 'committed', ?, 'application/octet-stream',
                        ?, ?, ?, ?, ?, 'stable')
                    """,
                arguments: [
                    id.uuidString, relativePath, bytes.count, digest,
                    finishedAt.timeIntervalSince1970, finishedAt.timeIntervalSince1970,
                    finishedAt.addingTimeInterval(ArtifactRecord.retentionInterval).timeIntervalSince1970
                ]
            )
            if linkToTask {
                try db.execute(
                    sql: "INSERT INTO task_artifacts (task_id, artifact_id, ordinal) VALUES (?, ?, ?)",
                    arguments: [taskID.uuidString, id.uuidString, ordinal]
                )
            }
        }
    }

    func insertMediaReference(documentID: UUID, taskID: UUID, artifactID: UUID) throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "schemaID": MediaAnalysisDocument.schemaIdentifier,
            "schemaVersion": MediaAnalysisDocument.currentSchemaVersion,
            "documentID": documentID.uuidString,
            "taskID": taskID.uuidString,
            "items": [[
                "media": ["stableID": "media", "sourcePath": "/fixture.mov", "displayName": "fixture.mov"],
                "summaryMetrics": [], "facets": [], "moments": [], "suggestedTags": [],
                "report": ["artifactID": artifactID.uuidString, "relativePath": "published/reference"]
            ]],
            "suggestedTags": [], "actions": [],
            "managedTagLedger": ["mediaEntries": []],
            "createdAt": 1
        ])
        try database.databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO media_analysis_documents (
                        document_id, task_id, schema_id, schema_version, payload,
                        created_at, reconciliation_state
                    ) VALUES (?, ?, 'mediaAnalysis.v1', 1, ?, 1, 'stable')
                    """,
                arguments: [documentID.uuidString, taskID.uuidString, payload]
            )
        }
    }

    func taskExists(_ id: UUID) throws -> Bool {
        try database.databasePool.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM task_records WHERE task_id = ?)", arguments: [id.uuidString])!
        }
    }

    func artifactExists(_ id: UUID) throws -> Bool {
        try database.databasePool.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM artifact_records WHERE artifact_id = ?)", arguments: [id.uuidString])!
        }
    }

    func artifactDiagnostic(_ id: UUID) throws -> (attempts: Int, reason: String?)? {
        try database.databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT cleanup_attempts, reconciliation_reason FROM artifact_records WHERE artifact_id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return (row["cleanup_attempts"], row["reconciliation_reason"])
        }
    }

    func url(for artifactID: UUID, taskID: UUID) -> URL {
        artifactRoot.appendingPathComponent("published", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
            .appendingPathComponent(artifactID.uuidString, isDirectory: true)
            .appendingPathComponent("payload")
    }
}

private final class FailOnceFileManager: FileManager, @unchecked Sendable {
    private let targetPath: String
    private var failsNextRemoval = true

    init(target: URL) {
        targetPath = target.resolvingSymlinksInPath().path
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.path == targetPath, failsNextRemoval {
            failsNextRemoval = false
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: URL)
    }
}
