import CryptoKit
import Foundation
import XCTest
@testable import OpenFinderCore

final class ArtifactResultServiceTests: XCTestCase {
    func testContextCommitRemapsUnknownFileAndPreservesInlineArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactResultContext-\(UUID())", isDirectory: true)
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        let output = workspaceRoot.appendingPathComponent("output", isDirectory: true)
        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let payload = Data("generic-file".utf8)
        try payload.write(to: output.appendingPathComponent("result.bin"))
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let file = PluginFileArtifact(
            relativePath: "result.bin",
            mediaType: "application/octet-stream",
            byteCount: payload.count,
            sha256: digest
        )
        let taskID = UUID()
        let context = PluginResultHandlingContext(
            resultSchemaID: "fixture.unknown.v1",
            pluginID: "fixture.unknown",
            pluginVersion: "1.0.0",
            actionID: "inspect",
            taskID: taskID,
            events: [.result(
                status: "success",
                message: "generic",
                clipboard: nil,
                artifacts: [
                    .init(type: "inline.fixture", content: "inline"),
                    .init(type: "file.fixture", file: file)
                ]
            )],
            outputDirectory: output
        )
        let workspace = PluginExecutionWorkspace(
            taskRoot: workspaceRoot,
            tempDirectory: workspaceRoot.appendingPathComponent("temp"),
            outputDirectory: output,
            cleanupPolicy: .removeTaskRootAfterExecution
        )
        let metadata = InMemoryArtifactMetadataBackend()
        let service = ArtifactResultService(
            store: try ArtifactStore(root: storeRoot, metadata: metadata),
            metadata: metadata
        )

        let committed = try await service.commit(
            context,
            workspace: workspace,
            markEffectsCommitted: {},
            cleanupWorkspace: { try workspace.cleanup() }
        )
        let projection = try await PluginResultHandlerRegistry.standard.handle(committed)
        let unknown = try XCTUnwrap(projection.project(UnknownPluginResult.self))
        let committedFile = try XCTUnwrap(unknown.artifacts[1].file)
        let records = await service.query(taskID: taskID, schemaID: "fixture.unknown.v1")
        let opened = try await service.open(records[0].id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceRoot.path))
        XCTAssertEqual(unknown.outputDirectory, storeRoot.standardizedFileURL)
        XCTAssertEqual(unknown.artifacts[0].content, "inline")
        XCTAssertNotEqual(committedFile.relativePath, file.relativePath)
        XCTAssertEqual(opened, payload)
    }

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
