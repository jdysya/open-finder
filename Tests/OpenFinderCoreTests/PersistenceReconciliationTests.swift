import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import OpenFinderCore

final class PersistenceReconciliationTests: XCTestCase {
    func testMissingMediaAssetRemainsDiagnosable() async throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceReconciliation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite"))
        let taskID = UUID()
        let artifactID = UUID()
        let documentID = UUID()
        try insertTask(taskID, database: database)
        try insertMissingArtifact(artifactID, taskID: taskID, database: database)
        let payload = try mediaPayload(documentID: documentID, taskID: taskID, artifactID: artifactID)
        try await database.databasePool.write { db in
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
        let maintenance = PersistenceMaintenance(
            databasePool: database.databasePool,
            artifactRoot: artifactRoot,
            clock: { Date(timeIntervalSince1970: 10_000) }
        )

        // When
        let first = await maintenance.runAtStartup()
        let second = await maintenance.runPeriodically()

        // Then
        XCTAssertTrue(first.issues.contains {
            $0.kind == .missingArtifactFile && $0.artifactID == artifactID
        })
        XCTAssertTrue(first.issues.contains {
            $0.kind == .missingMediaAsset && $0.artifactID == artifactID && $0.documentID == documentID
        })
        XCTAssertEqual(first.issues, second.issues)
        try await database.databasePool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifact_records"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_analysis_documents"), 1)
        }
        print("reconciliation_fixture missing_file=diagnosed missing_media_asset=diagnosed rows_preserved=2 idempotent=true")
    }

    private func insertTask(_ id: UUID, database: AppDatabase) throws {
        try database.databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO task_descriptors (
                        task_id, schema_version, handler_id, payload_version, redacted_payload,
                        root_task_id, attempt, queue_ordinal, created_at
                    ) VALUES (?, 1, 'fixture', 1, X'7B7D', ?, 1, 1, 1)
                    """,
                arguments: [id.uuidString, id.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO task_records (
                        task_id, record_version, kind_payload, title, status, created_at,
                        input_summary, retry_count
                    ) VALUES (?, 1, X'7B7D', 'live', 'running', 1, '', 0)
                    """,
                arguments: [id.uuidString]
            )
        }
    }

    private func insertMissingArtifact(_ id: UUID, taskID: UUID, database: AppDatabase) throws {
        let bytes = Data("missing".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try database.databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO artifact_records (
                        artifact_id, record_version, schema_id, state, relative_path,
                        media_type, byte_count, sha256, staged_at, finished_at,
                        retention_deadline, reconciliation_state
                    ) VALUES (?, 1, 'mediaAnalysis.v1', 'committed', ?, 'text/plain',
                        ?, ?, 1, 2, 999999, 'stable')
                    """,
                arguments: [
                    id.uuidString,
                    "published/\(taskID.uuidString)/\(id.uuidString)/missing.txt",
                    bytes.count,
                    digest
                ]
            )
            try db.execute(
                sql: "INSERT INTO task_artifacts (task_id, artifact_id, ordinal) VALUES (?, ?, 0)",
                arguments: [taskID.uuidString, id.uuidString]
            )
        }
    }

    private func mediaPayload(documentID: UUID, taskID: UUID, artifactID: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaID": MediaAnalysisDocument.schemaIdentifier,
            "schemaVersion": MediaAnalysisDocument.currentSchemaVersion,
            "documentID": documentID.uuidString,
            "taskID": taskID.uuidString,
            "items": [[
                "media": ["stableID": "media", "sourcePath": "/fixture.mov", "displayName": "fixture.mov"],
                "summaryMetrics": [], "facets": [], "moments": [], "suggestedTags": [],
                "report": ["artifactID": artifactID.uuidString, "relativePath": "published/missing"]
            ]],
            "suggestedTags": [], "actions": [],
            "managedTagLedger": ["mediaEntries": []],
            "createdAt": 1
        ])
    }
}
