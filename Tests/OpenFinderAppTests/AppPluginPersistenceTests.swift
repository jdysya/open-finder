import CryptoKit
import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppPluginPersistenceTests: XCTestCase {
    func testHTTPMediaAnalysisArtifactSurvivesApplicationServicesRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPluginPersistenceRestart-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("open-finder.sqlite")
        let video = root.appendingPathComponent("restart-video.mp4")
        try Data("restart-video".utf8).write(to: video)
        let item = try await LocalFileProvider().stat(.local(path: video.path))
        let http = FileAnalysisPluginRunner(videoPath: video.path)
        let app = AppPluginFixture.app(
            root: root,
            process: RecordingPluginRunner(),
            http: http,
            taskDatabaseURL: databaseURL
        )
        let (plugin, action) = persistencePlugin(root: root)
        app.setPluginConfigValue("http://127.0.0.1:8765", pluginID: plugin.id, key: "serverURL")
        let secretSaved = await app.setPluginSecret(
            "fixture-token",
            pluginID: plugin.id,
            key: "serverToken"
        )
        XCTAssertTrue(secretSaved)

        app.runPlugin(plugin, action: action, items: [item], pane: app.leftPane)
        try await AppPluginFixture.waitUntil {
            let records = await app.taskQueue.history()
            return records.count == 1 && records[0].status == .succeeded
        }

        let captured = await http.captured()
        let request = try XCTUnwrap(captured.first)
        let workspaceRoot = URL(fileURLWithPath: request.input.tempDirectory)
            .deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceRoot.path))

        let restarted = ApplicationServices(dependencies: .init(
            supportDirectory: root,
            taskDatabaseURL: databaseURL
        ))
        let results = try XCTUnwrap(restarted.artifactResults)
        let committed = await results.query(
            taskID: request.input.taskID,
            schemaID: MediaAnalysisDocument.schemaIdentifier
        )
        let artifact = try XCTUnwrap(committed.first)
        let payload = try await results.open(artifact.id)
        let document = try JSONDecoder.openFinder.decode(MediaAnalysisDocument.self, from: payload)
        let artifactURL = try await results.fileURL(for: artifact.id)

        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(artifact.state, .committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path))
        XCTAssertEqual(document.taskID, request.input.taskID)
        XCTAssertEqual(document.items.first?.media.sourcePath, video.path)
        print(
            "ARTIFACT_RESTART_QA workspaceClean=true taskID=\(request.input.taskID) " +
                "artifactID=\(artifact.id) relativePath=\(artifact.relativePath) " +
                "sha256=\(artifact.sha256) documentID=\(document.documentID)"
        )
    }

    func testHTTPMediaAnalysisResultRemainsPresentedAfterWorkspaceCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPluginPersistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("video.mp4")
        try Data("video".utf8).write(to: video)
        let item = try await LocalFileProvider().stat(.local(path: video.path))
        let process = RecordingPluginRunner()
        let http = FileAnalysisPluginRunner(videoPath: video.path)
        let keychain = InMemoryKeychainStore()
        let app = AppPluginFixture.app(root: root, process: process, http: http, keychain: keychain)
        let (plugin, action) = persistencePlugin(root: root)
        app.setPluginConfigValue("http://127.0.0.1:8765", pluginID: plugin.id, key: "serverURL")
        let secretSaved = await app.setPluginSecret("fixture-token", pluginID: plugin.id, key: "serverToken")
        XCTAssertTrue(secretSaved)

        app.runPlugin(plugin, action: action, items: [item], pane: app.leftPane)
        try await AppPluginFixture.waitUntil {
            let records = await app.taskQueue.history()
            return records.count == 1
                && records[0].status == .succeeded
                && app.presentedPluginResult != nil
        }

        let captured = await http.captured()
        let request = try XCTUnwrap(captured.first)
        let records = await app.taskQueue.history()
        XCTAssertEqual(records.map(\.id), [request.input.taskID])
        XCTAssertEqual(records.first?.status, .succeeded)
        let workspaceRoot = URL(fileURLWithPath: request.input.tempDirectory).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceRoot.path))
        let projection = try XCTUnwrap(app.presentedPluginResult)
        XCTAssertEqual(projection.resultSchemaID, MediaAnalysisDocument.schemaIdentifier)
        XCTAssertEqual(projection.handlerIdentifier, .mediaAnalysis)
        XCTAssertNotNil(projection.project(MediaAnalysisDocument.self))
        XCTAssertEqual(
            PluginRendererCatalog.standard.renderer(for: projection).identifier,
            .mediaAnalysis
        )
    }

    private func persistencePlugin(
        root: URL
    ) -> (LoadedPlugin, PluginActionManifest) {
        let action = PluginActionManifest(
            id: "analyze-video",
            title: "Analyze Video",
            category: nil,
            selection: .init(minItems: 1, maxItems: nil, allowDirectories: false),
            match: nil,
            output: .init(
                resultType: MediaAnalysisDocument.schemaIdentifier,
                canCopyToClipboard: false
            )
        )
        let manifest = PluginManifest(
            schemaVersion: 2,
            id: "fixture.persistence",
            name: "Video Analyzer",
            version: "1.0.0",
            description: nil,
            author: nil,
            execution: .http(protocolVersion: 1, endpointConfigurationKey: "serverURL", tokenSecretKey: "serverToken"),
            actions: [action],
            permissions: .init(
                readFiles: "selected",
                writeFiles: "taskOutput",
                network: .init(required: true, hosts: ["127.0.0.1"]),
                clipboardWrite: false,
                clipboardRead: false,
                keychainSecrets: ["serverToken"],
                remoteAccounts: false,
                runExternalCommands: false
            ),
            configuration: [.init(key: "serverURL", type: "string", title: "Server", required: true)]
        )
        return (LoadedPlugin(manifest: manifest, directory: root), action)
    }
}

private actor FileAnalysisPluginRunner: PluginRunner {
    private let videoPath: String
    private var requests: [PluginRunRequest] = []

    init(videoPath: String) {
        self.videoPath = videoPath
    }

    func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        requests.append(request)
        let output = URL(fileURLWithPath: request.input.outputDirectory, isDirectory: true)
        let result = MediaAnalysisDocument(
            documentID: request.input.taskID,
            taskID: request.input.taskID,
            items: [.init(
                media: .init(
                    stableID: "fixture-video",
                    sourcePath: videoPath,
                    displayName: "video.mp4"
                ),
                summaryMetrics: [.init(key: "totalFrames", value: 0, unit: .count)],
                facets: [],
                moments: [],
                suggestedTags: [],
                report: nil
            )],
            suggestedTags: [],
            actions: MediaAnalysisAction.standard,
            managedTagLedger: .init(mediaEntries: []),
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        let data = try JSONEncoder.openFinder.encode(result)
        try data.write(to: output.appendingPathComponent("result.json"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let artifact = PluginArtifact(
            type: MediaAnalysisDocument.schemaIdentifier,
            file: .init(
                relativePath: "result.json",
                mediaType: "application/json",
                byteCount: data.count,
                sha256: hash
            )
        )
        request.onEvent?(.progress(.init(
            fraction: 1,
            message: "1 of 1",
            phase: "finalizing",
            completed: 1,
            total: 1,
            unit: "videos"
        )))
        return .init(
            exitCode: 0,
            events: [.result(status: "success", message: "done", clipboard: nil, artifacts: [artifact])],
            stdout: "",
            stderr: ""
        )
    }

    func cancel(taskID: UUID) async {}
    func captured() -> [PluginRunRequest] { requests }
}
