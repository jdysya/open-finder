import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import OpenFinderCore

final class PersistenceReconciliationTests: XCTestCase {
    func testOrphanedFilesAndUnlinkedArtifactConverge() async throws {
        // Given
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }
        let taskID = UUID()
        let unlinkedID = UUID()
        let stagedID = UUID()
        let publishedID = UUID()
        try fixture.insertTask(taskID, status: .running, finishedAt: nil, ordinal: 1)
        try fixture.insertArtifact(
            unlinkedID, taskID: taskID, finishedAt: Date(timeIntervalSince1970: 2), linkToTask: false
        )
        let stagedPayload = try writePayload(root: fixture.artifactRoot,
            relativePath: ".staging/\(taskID.uuidString)/\(stagedID.uuidString)/payload", contents: "staged")
        let publishedPayload = try writePayload(root: fixture.artifactRoot,
            relativePath: "published/\(taskID.uuidString)/\(publishedID.uuidString)/report.json", contents: "published")
        let maintenance = PersistenceMaintenance(databasePool: fixture.database.databasePool,
            artifactRoot: fixture.artifactRoot, clock: { Date(timeIntervalSince1970: 10_000) })

        // When
        let first = await maintenance.runAtStartup()
        let second = await maintenance.runPeriodically()

        // Then
        XCTAssertEqual(Set(first.removedArtifactIDs), [unlinkedID, publishedID])
        XCTAssertEqual(first.removedStagingPaths.count, 1)
        XCTAssertTrue(first.removedStagingPaths[0].hasSuffix(
            "/.staging/\(taskID.uuidString)/\(stagedID.uuidString)/payload"
        ))
        XCTAssertFalse(try fixture.artifactExists(unlinkedID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedPayload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: publishedPayload.path))
        XCTAssertTrue(second.removedArtifactIDs.isEmpty)
        XCTAssertTrue(second.removedStagingPaths.isEmpty)
        let outsideRoot = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let sentinelID = UUID()
        let sentinel = try writePayload(root: outsideRoot,
            relativePath: "published/\(taskID.uuidString)/\(sentinelID.uuidString)/report.json",
            contents: "outside-sentinel")
        let backupRoot = fixture.root.appendingPathComponent("artifacts-backup", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.artifactRoot, to: backupRoot)
        try FileManager.default.createSymbolicLink(at: fixture.artifactRoot, withDestinationURL: outsideRoot)
        let replacedPeriodic = await maintenance.runPeriodically()
        let symlinkedStartup = await PersistenceMaintenance(databasePool: fixture.database.databasePool,
            artifactRoot: fixture.artifactRoot).runAtStartup()
        XCTAssertTrue(replacedPeriodic.issues.contains { $0.kind == .cleanupFailure })
        XCTAssertTrue(symlinkedStartup.issues.contains { $0.kind == .cleanupFailure })
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside-sentinel")
        XCTAssertTrue(try fixture.taskExists(taskID))
        let pathHash = SHA256.hash(data: Data(stagedPayload.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        print("orphan_fixture staging=1 published_named=1 unlinked=1 root_refused=2 sentinel=stable path_sha256=\(pathHash)")
    }

    func testOrphanedMediaDocumentAndManagedTagConverge() async throws {
        // Given
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }
        let taskID = UUID()
        let documentID = UUID()
        let missingDocumentID = UUID()
        let orphanTaskID = UUID()
        try fixture.insertTask(taskID, status: .running, finishedAt: nil, ordinal: 1)
        let payload = try mediaPayload(
            documentID: documentID,
            taskID: orphanTaskID,
            artifactID: UUID()
        )
        try await fixture.database.databasePool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(
                sql: """
                    INSERT INTO media_analysis_documents (
                        document_id, task_id, schema_id, schema_version, payload,
                        created_at, reconciliation_state
                    ) VALUES (?, ?, 'mediaAnalysis.v1', 1, ?, 1, 'stable')
                    """,
                arguments: [documentID.uuidString, orphanTaskID.uuidString, payload]
            )
            try db.execute(
                sql: """
                    INSERT INTO media_managed_tags (
                        document_id, stable_media_id, source_path, display_name,
                        tag_name, ordinal, managed_at
                    ) VALUES (?, 'media', '/fixture.mov', 'fixture.mov', 'tag', 0, 1)
                    """,
                arguments: [missingDocumentID.uuidString]
            )
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let maintenance = PersistenceMaintenance(
            databasePool: fixture.database.databasePool,
            artifactRoot: fixture.artifactRoot
        )

        // When
        let report = await maintenance.runAtStartup()

        // Then
        XCTAssertTrue(report.issues.contains {
            $0.kind == .orphanedMediaDocument && $0.documentID == documentID
        })
        XCTAssertTrue(report.issues.contains { $0.kind == .orphanedManagedTag })
        try await fixture.database.databasePool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_analysis_documents"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_managed_tags"), 0)
        }
        print("media_orphan_fixture documents_removed=1 managed_tags_removed=1")
    }

    func testMalformedArtifactAndMediaRowsAreDiagnosedAndPreserved() async throws {
        // Given
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }
        let taskID = UUID()
        let (malformedArtifactID, malformedDocumentID) = ("not-an-artifact-uuid", "not-a-document-uuid")
        let linkedArtifactID = UUID()
        try fixture.insertTask(
            taskID,
            status: .failed,
            finishedAt: Date(timeIntervalSince1970: 2),
            ordinal: 1
        )
        try fixture.insertArtifact(
            linkedArtifactID, taskID: taskID, finishedAt: Date(timeIntervalSince1970: 2), linkToTask: false
        )
        let artifactPayload = try writePayload(
            root: fixture.artifactRoot,
            relativePath: "published/malformed/payload",
            contents: "malformed"
        )
        let bytes = try Data(contentsOf: artifactPayload)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try await fixture.database.databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO artifact_records (
                        artifact_id, record_version, schema_id, state, relative_path,
                        media_type, byte_count, sha256, staged_at, finished_at,
                        retention_deadline, reconciliation_state
                    ) VALUES (?, 1, 'fixture', 'committed', 'published/malformed/payload',
                        'text/plain', ?, ?, 1, 2, 999999, 'stable')
                    """,
                arguments: [malformedArtifactID, bytes.count, digest]
            )
            try db.execute(
                sql: """
                    INSERT INTO media_analysis_documents (
                        document_id, task_id, schema_id, schema_version, payload,
                        created_at, reconciliation_state
                    ) VALUES (?, ?, 'mediaAnalysis.v1', 1, X'7B', 1, 'stable')
                    """,
                arguments: [malformedDocumentID, taskID.uuidString]
            )
        }
        try await fixture.database.databasePool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(
                sql: "INSERT INTO task_artifacts (task_id, artifact_id, ordinal) VALUES (?, ?, 0)",
                arguments: ["not-a-task-uuid", linkedArtifactID.uuidString]
            )
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let maintenance = PersistenceMaintenance(
            databasePool: fixture.database.databasePool,
            artifactRoot: fixture.artifactRoot,
            clock: { Date(timeIntervalSince1970: 4_000_000) }
        )

        // When
        let report = await maintenance.runAtStartup()

        // Then
        XCTAssertTrue(report.issues.contains { $0.kind == .corruptArtifactRow })
        XCTAssertTrue(report.issues.contains {
            $0.kind == .corruptArtifactRow && $0.artifactID == linkedArtifactID && $0.taskID == nil })
        XCTAssertTrue(report.issues.contains { $0.kind == .corruptMediaDocument })
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactPayload.path))
        XCTAssertTrue(try fixture.artifactExists(linkedArtifactID))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.url(for: linkedArtifactID, taskID: taskID).path))
        XCTAssertTrue(try fixture.taskExists(taskID))
        try await fixture.database.databasePool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifact_records"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_artifacts"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_analysis_documents"), 1)
        }
        print("malformed_fixture artifact_rows=2 malformed_links=1 media_rows=1 preserved=true")
    }

    func testMissingMediaAssetRemainsDiagnosable() async throws {
        // Given
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }
        let database = fixture.database
        let taskID = UUID()
        let artifactID = UUID()
        let documentID = UUID()
        try fixture.insertTask(taskID, status: .running, finishedAt: nil, ordinal: 1)
        try fixture.insertArtifact(
            artifactID,
            taskID: taskID,
            finishedAt: Date(timeIntervalSince1970: 2)
        )
        try FileManager.default.removeItem(at: fixture.url(for: artifactID, taskID: taskID))
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
            artifactRoot: fixture.artifactRoot,
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

    private func writePayload(root: URL, relativePath: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }
}
