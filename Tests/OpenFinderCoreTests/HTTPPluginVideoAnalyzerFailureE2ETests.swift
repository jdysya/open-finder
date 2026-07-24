import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginVideoAnalyzerFailureE2ETests: XCTestCase {
    func testWrongTokenAndMalformedInputAreRejectedWithoutSecretDisclosure() async throws {
        let repository = try RealHTTPVideoAnalyzerTestSupport.repository()
        let workspace = try RealHTTPVideoAnalyzerWorkspace(label: "rejection")
        let fixture = try VideoAnalyzerFixtureProcess(repository: repository, root: workspace.root)
        defer {
            RealHTTPVideoAnalyzerTestSupport.assertClean(fixture.stop())
            workspace.remove()
        }
        let wrongToken = "wrong-\(UUID().uuidString.lowercased())"
        let response = try await rawRequest(
            fixture: fixture, route: "capabilities", method: "GET", token: wrongToken, body: nil
        )
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(response.object["code"] as? String, "unauthorized")
        XCTAssertFalse(String(decoding: response.data, as: UTF8.self).contains(wrongToken))

        let malformed = try await rawRequest(
            fixture: fixture, route: "jobs", method: "POST", token: fixture.token,
            body: Data(#"{"schemaVersion":1}"#.utf8)
        )
        XCTAssertEqual(malformed.status, 400)
        XCTAssertEqual(malformed.object["code"] as? String, "invalid_request")

        let keychain = InMemoryKeychainStore()
        try keychain.setSecret(wrongToken, for: RealHTTPVideoAnalyzerTestSupport.credentialReference)
        let runner = HTTPPluginRunner(credentialStore: keychain)
        do {
            _ = try await runner.run(RealHTTPVideoAnalyzerTestSupport.request(
                taskID: UUID(), fixture: fixture, workspace: workspace
            ))
            XCTFail("Expected wrong-token rejection")
        } catch {
            XCTAssertNotNil(error as? HTTPPluginError)
            XCTAssertFalse(error.localizedDescription.contains(wrongToken))
            XCTAssertFalse(error.localizedDescription.contains(fixture.token))
        }
        let recorded = try Data(contentsOf: fixture.historyURL) + Data(contentsOf: fixture.logURL)
        XCTAssertFalse(recorded.contains(Data(wrongToken.utf8)))
        XCTAssertFalse(recorded.contains(Data(fixture.token.utf8)))
        XCTAssertFalse(try fixture.history().contains { $0.kind == "submission" })
    }

    func testTaskQueueRetryAfterServerCrashUsesNewIDAndPreservesConfiguration() async throws {
        let repository = try RealHTTPVideoAnalyzerTestSupport.repository()
        let firstWorkspace = try RealHTTPVideoAnalyzerWorkspace(label: "crash-first")
        let secondWorkspace = try RealHTTPVideoAnalyzerWorkspace(label: "crash-retry")
        let firstFixture = try VideoAnalyzerFixtureProcess(repository: repository, root: firstWorkspace.root)
        var secondFixture: VideoAnalyzerFixtureProcess?
        defer {
            RealHTTPVideoAnalyzerTestSupport.assertClean(firstFixture.stop())
            if let secondFixture { RealHTTPVideoAnalyzerTestSupport.assertClean(secondFixture.stop()) }
            firstWorkspace.remove()
            secondWorkspace.remove()
        }
        let (firstRunner, _) = try RealHTTPVideoAnalyzerTestSupport.configuredRunner(fixture: firstFixture)
        let active = ActiveRealHTTPFixture(fixture: firstFixture, runner: firstRunner, workspace: firstWorkspace)
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let recorder = RealHTTPEventRecorder()
        let preservedConfig = [
            "fixtureScenario": "success",
            "fixtureGatePath": firstWorkspace.gate.path,
            "useJoyTag": "false"
        ]
        let request = TaskRequest(
            kind: .plugin(pluginID: "fixture.video-analyzer", actionID: "analyze"),
            title: "Fixture analysis",
            resourceKey: "video-analysis"
        ) { context in
            try await active.run(context: context, config: preservedConfig, recorder: recorder)
        }
        let firstID = try await queue.enqueue(request)
        try await recorder.wait { events in
            events.filter { if case .progress = $0 { true } else { false } }.count >= 2
        }

        let crashReceipt = firstFixture.crash()
        XCTAssertTrue(crashReceipt.exited)
        let firstRecord = try await queue.waitForTerminalStatus(firstID, timeout: 8)
        XCTAssertEqual(firstRecord.status, .failed)
        XCTAssertTrue(firstRecord.errorMessage?.contains("HTTP plugin transport failed") == true)
        XCTAssertFalse(firstRecord.errorMessage?.contains(firstFixture.token) == true)

        try firstWorkspace.openGate()
        let restarted = try VideoAnalyzerFixtureProcess(repository: repository, root: secondWorkspace.root)
        secondFixture = restarted
        let (secondRunner, _) = try RealHTTPVideoAnalyzerTestSupport.configuredRunner(fixture: restarted)
        await active.update(fixture: restarted, runner: secondRunner, workspace: secondWorkspace)
        let retryID = try await queue.retry(firstID)
        let retryRecord = try await queue.waitForTerminalStatus(retryID, timeout: 8)

        XCTAssertNotEqual(firstID, retryID)
        XCTAssertEqual(retryRecord.status, .succeeded)
        XCTAssertEqual(try firstFixture.history().first { $0.kind == "submission" }?.taskID, firstID)
        let retrySubmission = try XCTUnwrap(restarted.history().first { $0.kind == "submission" })
        XCTAssertEqual(retrySubmission.taskID, retryID)
        XCTAssertEqual(retrySubmission.config?["fixtureScenario"], preservedConfig["fixtureScenario"])
        XCTAssertEqual(retrySubmission.config?["fixtureGatePath"], preservedConfig["fixtureGatePath"])
        XCTAssertEqual(retrySubmission.config?["useJoyTag"], preservedConfig["useJoyTag"])
    }

    private func rawRequest(
        fixture: VideoAnalyzerFixtureProcess,
        route: String,
        method: String,
        token: String,
        body: Data?
    ) async throws -> (status: Int, data: Data, object: [String: Any]) {
        var request = URLRequest(url: URL(string: "\(fixture.endpoint)/openfinder/plugin/v1/\(route)")!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("1", forHTTPHeaderField: "OpenFinder-Plugin-Protocol")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (http.statusCode, data, object)
    }
}

private actor ActiveRealHTTPFixture {
    private var fixture: VideoAnalyzerFixtureProcess
    private var runner: HTTPPluginRunner
    private var workspace: RealHTTPVideoAnalyzerWorkspace

    init(fixture: VideoAnalyzerFixtureProcess, runner: HTTPPluginRunner, workspace: RealHTTPVideoAnalyzerWorkspace) {
        self.fixture = fixture
        self.runner = runner
        self.workspace = workspace
    }

    func update(
        fixture: VideoAnalyzerFixtureProcess,
        runner: HTTPPluginRunner,
        workspace: RealHTTPVideoAnalyzerWorkspace
    ) {
        self.fixture = fixture
        self.runner = runner
        self.workspace = workspace
    }

    func run(
        context: TaskExecutionContext,
        config: [String: String],
        recorder: RealHTTPEventRecorder
    ) async throws -> TaskResult {
        let run = try await runner.run(RealHTTPVideoAnalyzerTestSupport.request(
            taskID: context.id, fixture: fixture, workspace: workspace, config: config,
            onEvent: { event in
                recorder.append(event)
                if case .progress(let progress) = event {
                    Task { await context.updateProgress(.init(
                        fraction: progress.fraction, phase: progress.phase, detail: progress.message,
                        completed: progress.completed, total: progress.total, unit: progress.unit
                    )) }
                }
            }
        ))
        guard run.exitCode == 0 else { throw HTTPPluginError.invalidResponse("fixture result failed") }
        return .success(summary: "completed", clipboard: nil)
    }
}
