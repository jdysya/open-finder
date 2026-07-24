import CryptoKit
import Foundation
import XCTest
@testable import OpenFinderCore

final class ArtifactResultServiceTests: XCTestCase {
    func testCommitQueryOpenAndExportCommittedArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactResultService-\(UUID())", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        let exportRoot = root.appendingPathComponent("export", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let payload = Data("artifact-result".utf8)
        let source = workspace.appendingPathComponent("result.txt")
        try payload.write(to: source)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let artifact = PluginFileArtifact(
            relativePath: "result.txt",
            mediaType: "text/plain",
            byteCount: payload.count,
            sha256: digest
        )
        let metadata = InMemoryArtifactMetadataBackend()
        let store = try ArtifactStore(root: storeRoot, metadata: metadata)
        let service = ArtifactResultService(store: store, metadata: metadata)
        let taskID = UUID()

        let committed = try await service.commit(
            taskID: taskID,
            schemaID: "fixture.v1",
            artifacts: [artifact],
            from: ConfinedArtifactReader(root: workspace),
            markEffectsCommitted: {},
            cleanupWorkspace: {}
        )
        let queried = await service.query(taskID: taskID, schemaID: "fixture.v1")
        let opened = try await service.open(committed[0].id)
        let exported = try await service.export(
            committed[0].id,
            to: exportRoot.appendingPathComponent("copy.txt")
        )

        XCTAssertEqual(queried, committed)
        XCTAssertEqual(opened, payload)
        XCTAssertEqual(try Data(contentsOf: exported), payload)
    }
}
