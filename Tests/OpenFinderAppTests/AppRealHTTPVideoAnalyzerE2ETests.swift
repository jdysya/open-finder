import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppRealHTTPVideoAnalyzerE2ETests: XCTestCase {
    func testAppModelRetryUsesActualHTTPRunnerNewServerIDAndCapturedConfig() async throws {
        guard let repository = try AppVideoAnalyzerFixtureProcess.repositoryIfAvailable() else {
            throw XCTSkip("Video Analyzer sibling repository or its .venv is absent.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppRealHTTPVideoAnalyzer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try AppVideoAnalyzerFixtureProcess(repository: repository, root: root)
        defer {
            XCTAssertTrue(fixture.stop())
            try? FileManager.default.removeItem(at: root)
        }
        let openFinder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plugin = try XCTUnwrap(PluginRegistry().scan(
            directory: openFinder.appendingPathComponent("ExamplePlugins")
        ).first { $0.id == "dev.openfinder.plugins.video-analyzer" })
        let video = root.appendingPathComponent("fixture.mp4")
        try Data("app-fixture-video".utf8).write(to: video)
        let item = try await LocalFileProvider().stat(.local(path: video.path))
        let keychain = InMemoryKeychainStore()
        let localCredentialStore = LocalPluginCredentialStore()
        let credentialResolver = PluginCredentialResolver(
            keychainStore: keychain,
            localStore: localCredentialStore
        )
        let app = AppPluginFixture.app(
            root: root,
            process: RecordingPluginRunner(),
            http: HTTPPluginRunner(credentialResolver: credentialResolver),
            checker: StubPluginConnectionChecker.ready,
            keychain: keychain,
            localCredentialStore: localCredentialStore
        )
        app.loadedPlugins = [plugin]
        app.setPluginConfigValue(fixture.endpoint, pluginID: plugin.id, key: "serverURL")
        app.setPluginConfigValue("false", pluginID: plugin.id, key: "useJoyTag")
        let secretSaved = await app.setPluginSecret(fixture.token, pluginID: plugin.id, key: "serverToken")
        XCTAssertTrue(secretSaved)

        app.runPlugin(plugin, action: plugin.manifest.actions[0], items: [item], pane: app.leftPane)
        try await AppPluginFixture.waitUntil {
            let records = await app.taskQueue.history()
            return records.count == 1 && records[0].status.isTerminal && app.presentedVideoAnalysis != nil
        }
        let firstSubmission = try XCTUnwrap(fixture.history().first { $0.kind == "submission" })
        let firstID = try XCTUnwrap(firstSubmission.taskID)
        let firstRecord = await app.taskQueue.record(for: firstID)
        XCTAssertEqual(firstRecord?.status, .succeeded)
        XCTAssertEqual(firstSubmission.config?["useJoyTag"], "false")
        let firstFrame = try XCTUnwrap(app.presentedVideoAnalysis?.videos[0].frames[0].imagePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFrame))

        app.setPluginConfigValue("http://127.0.0.1:9", pluginID: plugin.id, key: "serverURL")
        app.setPluginConfigValue("true", pluginID: plugin.id, key: "useJoyTag")
        let retryID = try await app.taskQueue.retry(firstID)
        let retryRecord = try await app.taskQueue.waitForTerminalStatus(retryID, timeout: 8)
        let submissions = try fixture.history().filter { $0.kind == "submission" }

        XCTAssertEqual(retryRecord.status, .succeeded)
        XCTAssertNotEqual(firstID, retryID)
        XCTAssertEqual(submissions.compactMap(\.taskID), [firstID, retryID])
        XCTAssertEqual(submissions.map { $0.config?["useJoyTag"] }, ["false", "false"])
        for taskID in [firstID, retryID] {
            let taskRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenFinderHTTPTasks/\(taskID.uuidString)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: taskRoot.path))
        }
        let historyData = try Data(contentsOf: fixture.historyURL)
        XCTAssertFalse(historyData.contains(Data(fixture.token.utf8)))
    }
}
