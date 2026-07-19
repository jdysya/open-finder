import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppPluginRoutingTests: XCTestCase {
    func testRoutesBothTransportsAndRetryUsesNewIDWithCapturedConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPluginRouting-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("video.mp4")
        try Data("video".utf8).write(to: file)
        let item = try await LocalFileProvider().stat(.local(path: file.path))
        let processRunner = RecordingPluginRunner()
        let httpRunner = RecordingPluginRunner(progress: .init(
            fraction: 0.5,
            message: "12 of 24",
            phase: "keyframes",
            completed: 12,
            total: 24,
            unit: "frames"
        ))
        let keychain = InMemoryKeychainStore()
        let app = AppPluginFixture.app(root: root, process: processRunner, http: httpRunner, keychain: keychain)
        let process = LoadedPlugin(
            manifest: AppPluginFixture.manifest(
                id: "fixture.process",
                execution: .process(runtime: .shell, entry: "run.sh")
            ),
            directory: root
        )
        let http = LoadedPlugin(
            manifest: AppPluginFixture.manifest(
                id: "fixture.http",
                execution: .http(protocolVersion: 1, endpointConfigurationKey: "serverURL", tokenSecretKey: "serverToken")
            ),
            directory: root
        )
        app.setPluginConfigValue("http://127.0.0.1:8765", pluginID: http.id, key: "serverURL")
        let secretSaved = await app.setPluginSecret("fixture-token", pluginID: http.id, key: "serverToken")
        XCTAssertTrue(secretSaved)

        app.runPlugin(process, action: process.manifest.actions[0], items: [item], pane: app.leftPane)
        app.runPlugin(http, action: http.manifest.actions[0], items: [item], pane: app.leftPane)
        try await AppPluginFixture.waitUntil {
            let records = await app.taskQueue.history()
            return records.count == 2 && records.allSatisfy(\.status.isTerminal)
        }

        let processRequests = await processRunner.captured()
        var httpRequests = await httpRunner.captured()
        XCTAssertEqual(processRequests.count, 1)
        XCTAssertEqual(httpRequests.count, 1)
        let records = await app.taskQueue.history()
        XCTAssertEqual(Set(records.map(\.id)), Set([processRequests[0].input.taskID, httpRequests[0].input.taskID]))
        let httpRecord = try XCTUnwrap(records.first { $0.id == httpRequests[0].input.taskID })
        try await AppPluginFixture.waitUntil {
            await app.taskQueue.record(for: httpRecord.id)?.progressDetail?.phase == "keyframes"
        }
        let detail = await app.taskQueue.record(for: httpRecord.id)?.progressDetail
        XCTAssertEqual(detail?.completed, 12)
        XCTAssertEqual(detail?.unit, "frames")

        app.setPluginConfigValue("http://127.0.0.1:9999", pluginID: http.id, key: "serverURL")
        let retryID = try await app.taskQueue.retry(httpRecord.id)
        _ = try await app.taskQueue.waitForTerminalStatus(retryID, timeout: 2)
        httpRequests = await httpRunner.captured()
        XCTAssertEqual(httpRequests.count, 2)
        XCTAssertNotEqual(httpRequests[0].input.taskID, httpRequests[1].input.taskID)
        XCTAssertEqual(httpRequests[1].input.taskID, retryID)
        XCTAssertEqual(httpRequests[1].input.config["serverURL"], "http://127.0.0.1:8765")
    }

    func testUnavailableConnectionBlocksSubmissionWithGuidance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPluginBlocked-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingPluginRunner()
        let guidance = "Start the Video Analyzer server, then test the connection again."
        let checker = StubPluginConnectionChecker(status: .init(
            state: .unavailable,
            issue: .serverUnavailable,
            guidance: guidance
        ))
        let app = AppPluginFixture.app(root: root, process: runner, http: runner, checker: checker)
        let plugin = LoadedPlugin(
            manifest: AppPluginFixture.manifest(
                id: "fixture.http",
                execution: .http(protocolVersion: 1, endpointConfigurationKey: "serverURL", tokenSecretKey: "serverToken")
            ),
            directory: root
        )
        app.runPlugin(plugin, action: plugin.manifest.actions[0], items: [], pane: app.leftPane)
        try await AppPluginFixture.waitUntil { app.statusMessage == guidance }

        let records = await app.taskQueue.history()
        let requests = await runner.captured()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(app.pluginConnectionStatus(for: plugin)?.issue, .serverUnavailable)
    }

    func testQueueCancellationReachesActiveHTTPTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPluginCancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let process = RecordingPluginRunner()
        let http = BlockingPluginRunner()
        let app = AppPluginFixture.app(root: root, process: process, http: http)
        let plugin = LoadedPlugin(
            manifest: AppPluginFixture.manifest(
                id: "fixture.http",
                execution: .http(protocolVersion: 1, endpointConfigurationKey: "serverURL", tokenSecretKey: "serverToken")
            ),
            directory: root
        )

        app.runPlugin(plugin, action: plugin.manifest.actions[0], items: [], pane: app.leftPane)
        try await AppPluginFixture.waitUntil { !(await http.started()).isEmpty }
        let started = await http.started()
        let taskID = try XCTUnwrap(started.first)
        app.cancelTask(taskID)
        try await AppPluginFixture.waitUntil {
            await app.taskQueue.record(for: taskID)?.status == .cancelled
        }

        let cancelled = await http.cancelled()
        let processRequests = await process.captured()
        XCTAssertEqual(cancelled, [taskID])
        XCTAssertTrue(processRequests.isEmpty)
    }
}
