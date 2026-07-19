import CryptoKit
import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppPluginPersistenceTests: XCTestCase {
    func testHTTPVideoResultPersistsBeforeWorkspaceCleanup() async throws {
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
        let action = PluginActionManifest(
            id: "analyze-video",
            title: "Analyze Video",
            category: nil,
            selection: .init(minItems: 1, maxItems: nil, allowDirectories: false),
            match: nil,
            output: .init(resultType: "videoAnalysisResult", canCopyToClipboard: false)
        )
        let manifest = PluginManifest(
            schemaVersion: 2,
            id: AppModel.videoAnalyzerPluginID,
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
        let plugin = LoadedPlugin(manifest: manifest, directory: root)
        app.setPluginConfigValue("http://127.0.0.1:8765", pluginID: plugin.id, key: "serverURL")
        let secretSaved = await app.setPluginSecret("fixture-token", pluginID: plugin.id, key: "serverToken")
        XCTAssertTrue(secretSaved)

        app.runPlugin(plugin, action: action, items: [item], pane: app.leftPane)
        try await AppPluginFixture.waitUntil { app.presentedVideoAnalysis != nil }

        let captured = await http.captured()
        let request = try XCTUnwrap(captured.first)
        let records = await app.taskQueue.history()
        XCTAssertEqual(records.map(\.id), [request.input.taskID])
        XCTAssertEqual(records.first?.status, .succeeded)
        let workspaceRoot = URL(fileURLWithPath: request.input.tempDirectory).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceRoot.path))
        let result = try XCTUnwrap(app.presentedVideoAnalysis)
        let framePath = try XCTUnwrap(result.videos.first?.frames.first?.imagePath)
        let reportPath = try XCTUnwrap(result.videos.first?.reportPath)
        XCTAssertTrue(framePath.contains("analysis/assets/\(request.input.taskID.uuidString)"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: framePath)), Data("frame".utf8))
        XCTAssertEqual(try String(contentsOfFile: reportPath, encoding: .utf8), "report")
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
        let frame = output.appendingPathComponent("frames/frame.jpg")
        let report = output.appendingPathComponent("reports/report.html")
        try FileManager.default.createDirectory(at: frame.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: frame)
        try Data("report".utf8).write(to: report)
        let result = VideoAnalysisResult(
            taskID: request.input.taskID,
            videos: [.init(
                path: videoPath,
                name: "video.mp4",
                summary: .init(totalFrames: 1, faceVisible: 1, explicit: 0, moderate: 0, partial: 0, none: 1),
                frames: [.init(
                    index: 0,
                    timestamp: 1,
                    imagePath: "frames/frame.jpg",
                    faceVisible: true,
                    faceCount: 1,
                    nudityLevel: .none,
                    summary: "frame",
                    tags: []
                )],
                suggestedTags: [],
                reportPath: "reports/report.html"
            )]
        )
        let data = try JSONEncoder.openFinder.encode(result)
        try data.write(to: output.appendingPathComponent("result.json"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let artifact = PluginArtifact(
            type: "videoAnalysisResult",
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
