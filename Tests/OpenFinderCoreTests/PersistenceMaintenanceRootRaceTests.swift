import Foundation
import GRDB
import XCTest
@testable import OpenFinderCore

final class PersistenceMaintenanceRootRaceTests: XCTestCase {
    func testRootReplacementCannotRedirectCleanupOutsidePinnedDirectory() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }
        let taskID = UUID()
        let diagnosticArtifactID = UUID()
        let artifactID = UUID()
        try fixture.insertTask(taskID, status: .running, finishedAt: nil, ordinal: 1)
        try fixture.insertArtifact(
            diagnosticArtifactID,
            taskID: taskID,
            finishedAt: Date(timeIntervalSince1970: 2)
        )
        try FileManager.default.removeItem(
            at: fixture.url(for: diagnosticArtifactID, taskID: taskID)
        )
        let outsideRoot = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let sentinel = outsideRoot.appendingPathComponent(
            ".staging/\(taskID.uuidString)/\(artifactID.uuidString)/payload"
        )
        try FileManager.default.createDirectory(
            at: sentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("outside-sentinel".utf8).write(to: sentinel)
        try FileManager.default.createDirectory(
            at: fixture.artifactRoot.appendingPathComponent(".staging"),
            withIntermediateDirectories: true
        )
        let swapper = RootSwapper(
            logicalRoot: fixture.artifactRoot,
            outsideRoot: outsideRoot,
            backupRoot: fixture.root.appendingPathComponent("artifacts-backup")
        )
        let swapRoot = DatabaseFunction("swap_artifact_root", argumentCount: 0) { _ in
            try swapper.swap()
            return nil
        }
        try await fixture.database.databasePool.write { db in
            db.add(function: swapRoot)
            try db.execute(
                sql: """
                    CREATE TRIGGER swap_root_after_diagnostic
                    AFTER UPDATE OF cleanup_attempts ON artifact_records
                    WHEN NEW.artifact_id = '\(diagnosticArtifactID.uuidString)'
                    BEGIN SELECT swap_artifact_root(); END
                    """
            )
        }
        let maintenance = PersistenceMaintenance(
            databasePool: fixture.database.databasePool,
            artifactRoot: fixture.artifactRoot
        )

        let report = await maintenance.runAtStartup()

        XCTAssertTrue(report.removedStagingPaths.isEmpty)
        XCTAssertTrue(report.issues.contains { $0.kind == .cleanupFailure })
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside-sentinel")
        print("root_race_fixture cleanup_failure=1 outside_sentinel=stable")
    }
}

private final class RootSwapper: @unchecked Sendable {
    private let logicalRoot: URL
    private let outsideRoot: URL
    private let backupRoot: URL

    init(logicalRoot: URL, outsideRoot: URL, backupRoot: URL) {
        self.logicalRoot = logicalRoot
        self.outsideRoot = outsideRoot
        self.backupRoot = backupRoot
    }

    func swap() throws {
        try FileManager.default.moveItem(at: logicalRoot, to: backupRoot)
        try FileManager.default.createSymbolicLink(
            at: logicalRoot,
            withDestinationURL: outsideRoot
        )
    }
}
