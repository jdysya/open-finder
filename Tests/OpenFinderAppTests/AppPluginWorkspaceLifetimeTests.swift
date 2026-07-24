import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppPluginWorkspaceLifetimeTests: XCTestCase {
    func testOrdinaryHTTPSuccessRemovesTaskWorkspace() async throws {
        let fixture = try makeFixture(name: "Success", runner: RecordingPluginRunner())
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.app.runPlugin(fixture.plugin, action: fixture.action, items: [], pane: fixture.app.leftPane)
        let record = try await waitForOnlyTerminalRecord(in: fixture.app)

        XCTAssertEqual(record.status, .succeeded)
        XCTAssertFalse(taskWorkspaceExists(record.id))
    }

    func testHTTPFailureRemovesTaskWorkspace() async throws {
        let fixture = try makeFixture(name: "Failure", runner: FailingPluginRunner())
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.app.runPlugin(fixture.plugin, action: fixture.action, items: [], pane: fixture.app.leftPane)
        let record = try await waitForOnlyTerminalRecord(in: fixture.app)

        XCTAssertEqual(record.status, .failed)
        XCTAssertFalse(taskWorkspaceExists(record.id))
    }

    func testExplicitHTTPCancellationRemovesTaskWorkspace() async throws {
        let runner = BlockingPluginRunner()
        let fixture = try makeFixture(name: "ExplicitCancellation", runner: runner)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.app.runPlugin(fixture.plugin, action: fixture.action, items: [], pane: fixture.app.leftPane)
        try await AppPluginFixture.waitUntil { !(await runner.started()).isEmpty }
        let started = await runner.started()
        let taskID = try XCTUnwrap(started.first)
        fixture.app.cancelTask(taskID)
        let record = try await fixture.app.taskQueue.waitForTerminalStatus(taskID, timeout: 2)

        XCTAssertEqual(record.status, .cancelled)
        XCTAssertFalse(taskWorkspaceExists(taskID))
    }

    func testRuntimeHTTPCancellationRemovesTaskWorkspace() async throws {
        let fixture = try makeFixture(name: "RuntimeCancellation", runner: RuntimeCancellingPluginRunner())
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.app.runPlugin(fixture.plugin, action: fixture.action, items: [], pane: fixture.app.leftPane)
        let record = try await waitForOnlyTerminalRecord(in: fixture.app)

        XCTAssertEqual(record.status, .cancelled)
        XCTAssertFalse(taskWorkspaceExists(record.id))
    }

    func testHTTPRetryUsesNewIDAndRemovesBothAttemptWorkspaces() async throws {
        let runner = RecordingPluginRunner()
        let fixture = try makeFixture(name: "Retry", runner: runner)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.app.runPlugin(fixture.plugin, action: fixture.action, items: [], pane: fixture.app.leftPane)
        let first = try await waitForOnlyTerminalRecord(in: fixture.app)
        let retryID = try await fixture.app.taskQueue.retry(first.id)
        let retry = try await fixture.app.taskQueue.waitForTerminalStatus(retryID, timeout: 2)
        let requests = await runner.captured()

        XCTAssertEqual(first.status, .succeeded)
        XCTAssertEqual(retry.status, .succeeded)
        XCTAssertEqual(requests.map(\.input.taskID), [first.id, retryID])
        XCTAssertNotEqual(first.id, retryID)
        XCTAssertFalse(taskWorkspaceExists(first.id))
        XCTAssertFalse(taskWorkspaceExists(retryID))
    }

    func testUnavailablePreflightDoesNotCreateHTTPWorkspace() async throws {
        let guidance = "Start the fixture service."
        let checker = StubPluginConnectionChecker(status: .init(
            state: .unavailable,
            issue: .serverUnavailable,
            guidance: guidance
        ))
        let fixture = try makeFixture(name: "Preflight", runner: RecordingPluginRunner(), checker: checker)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = workspaceChildren()

        fixture.app.runPlugin(fixture.plugin, action: fixture.action, items: [], pane: fixture.app.leftPane)
        try await AppPluginFixture.waitUntil { fixture.app.statusMessage == guidance }

        XCTAssertEqual(workspaceChildren(), before)
        let history = await fixture.app.taskQueue.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testCleanupFailureDoesNotReplaceHTTPSuccessAndEmitsSanitizedWarning() async throws {
        let fixture = try makeFixture(
            name: "CleanupFailureSuccess",
            runner: RecordingPluginRunner(),
            maintenance: failingMaintenance()
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.app.runPlugin(fixture.plugin, action: fixture.action, items: [], pane: fixture.app.leftPane)
        let record = try await waitForOnlyTerminalRecord(in: fixture.app)
        defer { try? FileManager.default.removeItem(at: PluginWorkspace.makeHTTP(taskID: record.id).taskRoot) }

        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(record.resultSummary, "done")
        await assertSanitizedCleanupWarning(for: record.id, in: fixture.app)
    }

    func testCleanupFailureDoesNotReplaceHTTPFailureAndEmitsSanitizedWarning() async throws {
        let fixture = try makeFixture(
            name: "CleanupFailureError",
            runner: FailingPluginRunner(),
            maintenance: failingMaintenance()
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.app.runPlugin(fixture.plugin, action: fixture.action, items: [], pane: fixture.app.leftPane)
        let record = try await waitForOnlyTerminalRecord(in: fixture.app)
        defer { try? FileManager.default.removeItem(at: PluginWorkspace.makeHTTP(taskID: record.id).taskRoot) }

        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.errorMessage, "Plugin execution failed.")
        await assertSanitizedCleanupWarning(for: record.id, in: fixture.app)
    }

    func testCleanupFailureDoesNotReplaceCancellationAndEmitsSanitizedWarning() async throws {
        let fixture = try makeFixture(
            name: "CleanupFailureCancellation",
            runner: RuntimeCancellingPluginRunner(),
            maintenance: failingMaintenance()
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.app.runPlugin(fixture.plugin, action: fixture.action, items: [], pane: fixture.app.leftPane)
        let record = try await waitForOnlyTerminalRecord(in: fixture.app)
        defer { try? FileManager.default.removeItem(at: PluginWorkspace.makeHTTP(taskID: record.id).taskRoot) }

        XCTAssertEqual(record.status, .cancelled)
        XCTAssertNil(record.errorMessage)
        await assertSanitizedCleanupWarning(for: record.id, in: fixture.app)
    }

    private func makeFixture(
        name: String,
        runner: any PluginRunner,
        checker: any PluginConnectionChecking = StubPluginConnectionChecker.ready,
        maintenance: PluginWorkspaceMaintenance = .live()
    ) throws -> (root: URL, app: AppModel, plugin: LoadedPlugin, action: PluginActionManifest) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPluginWorkspace\(name)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keychain = InMemoryKeychainStore()
        try keychain.setSecret(
            "fixture-token",
            for: PluginCredentialReference.keychain(
                pluginID: "fixture.http",
                key: "serverToken"
            )
        )
        let app = AppPluginFixture.app(
            root: root,
            process: RecordingPluginRunner(),
            http: runner,
            checker: checker,
            keychain: keychain,
            workspaceMaintenance: maintenance
        )
        let plugin = LoadedPlugin(
            manifest: AppPluginFixture.manifest(
                id: "fixture.http",
                execution: .http(
                    protocolVersion: 1,
                    endpointConfigurationKey: "serverURL",
                    tokenSecretKey: "serverToken"
                )
            ),
            directory: root
        )
        return (root, app, plugin, plugin.manifest.actions[0])
    }

    private func waitForOnlyTerminalRecord(in app: AppModel) async throws -> TaskRecord {
        try await AppPluginFixture.waitUntil {
            let records = await app.taskQueue.history()
            return records.count == 1 && records[0].status.isTerminal
        }
        let records = await app.taskQueue.history()
        return try XCTUnwrap(records.first)
    }

    private func taskWorkspaceExists(_ taskID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: PluginWorkspace.makeHTTP(taskID: taskID).taskRoot.path)
    }

    private func workspaceChildren() -> Set<String> {
        let root = PluginWorkspace.makeHTTP(taskID: UUID()).taskRoot.deletingLastPathComponent()
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(children.map(\.lastPathComponent))
    }

    private func failingMaintenance() -> PluginWorkspaceMaintenance {
        .live { workspace in
            throw CleanupFixtureError(details: "secret-marker \(workspace.taskRoot.path)")
        }
    }

    private func assertSanitizedCleanupWarning(for taskID: UUID, in app: AppModel) async {
        let warnings = await app.taskQueue.logs(for: taskID).filter { $0.level == "warning" }
        XCTAssertEqual(warnings.map(\.message), [PluginWorkspaceMaintenance.cleanupWarning])
        XCTAssertFalse(warnings.contains { $0.message.contains("secret-marker") })
        XCTAssertFalse(warnings.contains { $0.message.contains(taskID.uuidString) })
    }
}

private struct CleanupFixtureError: Error {
    let details: String
}
