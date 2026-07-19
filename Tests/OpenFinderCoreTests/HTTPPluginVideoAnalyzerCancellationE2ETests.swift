import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginVideoAnalyzerCancellationE2ETests: XCTestCase {
    func testRunningCancellationSendsDeleteAndProducesOneCancelledTerminal() async throws {
        let repository = try RealHTTPVideoAnalyzerTestSupport.repository()
        let workspace = try RealHTTPVideoAnalyzerWorkspace(label: "running-cancel")
        let fixture = try VideoAnalyzerFixtureProcess(repository: repository, root: workspace.root)
        defer {
            RealHTTPVideoAnalyzerTestSupport.assertClean(fixture.stop())
            workspace.remove()
        }
        let taskID = UUID()
        let recorder = RealHTTPEventRecorder()
        let (runner, _) = try RealHTTPVideoAnalyzerTestSupport.configuredRunner(fixture: fixture)
        let request = RealHTTPVideoAnalyzerTestSupport.request(
            taskID: taskID, fixture: fixture, workspace: workspace,
            config: ["fixtureScenario": "success", "fixtureGatePath": workspace.gate.path],
            onEvent: recorder.append
        )
        let running = Task { try await runner.run(request) }
        try await recorder.wait { events in
            events.filter { if case .progress = $0 { true } else { false } }.count >= 2
        }

        await runner.cancel(taskID: taskID)
        await assertCancellation(running)

        let history = try fixture.history()
        assertSingleCancellation(taskID: taskID, history: history)
    }

    func testQueuedCancellationNeverRunsAndEachJobHasOneCancelledTerminal() async throws {
        let repository = try RealHTTPVideoAnalyzerTestSupport.repository()
        let runningWorkspace = try RealHTTPVideoAnalyzerWorkspace(label: "queue-running")
        let queuedWorkspace = try RealHTTPVideoAnalyzerWorkspace(label: "queue-waiting")
        let fixture = try VideoAnalyzerFixtureProcess(repository: repository, root: runningWorkspace.root)
        defer {
            RealHTTPVideoAnalyzerTestSupport.assertClean(fixture.stop())
            runningWorkspace.remove()
            queuedWorkspace.remove()
        }
        let runningID = UUID()
        let queuedID = UUID()
        let recorder = RealHTTPEventRecorder()
        let (runner, _) = try RealHTTPVideoAnalyzerTestSupport.configuredRunner(fixture: fixture)
        let first = Task { try await runner.run(RealHTTPVideoAnalyzerTestSupport.request(
            taskID: runningID, fixture: fixture, workspace: runningWorkspace,
            config: ["fixtureScenario": "success", "fixtureGatePath": runningWorkspace.gate.path],
            onEvent: recorder.append
        )) }
        try await recorder.wait { events in
            events.filter { if case .progress = $0 { true } else { false } }.count >= 2
        }
        let second = Task { try await runner.run(RealHTTPVideoAnalyzerTestSupport.request(
            taskID: queuedID, fixture: fixture, workspace: queuedWorkspace,
            config: ["fixtureScenario": "success"]
        )) }
        let queuedEventPath = "/jobs/\(queuedID.uuidString.lowercased())/events"
        _ = try await RealHTTPVideoAnalyzerTestSupport.waitForHistory(fixture) { history in
            history.contains { $0.kind == "request" && $0.path?.hasSuffix(queuedEventPath) == true }
        }

        await runner.cancel(taskID: queuedID)
        await assertCancellation(second)
        await runner.cancel(taskID: runningID)
        await assertCancellation(first)

        let history = try fixture.history()
        assertSingleCancellation(taskID: queuedID, history: history)
        assertSingleCancellation(taskID: runningID, history: history)
        let submissions = history.filter { $0.kind == "submission" }.compactMap(\.taskID)
        XCTAssertEqual(Set(submissions), Set([runningID, queuedID]))
    }

    private func assertCancellation(
        _ task: Task<PluginRunResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertSingleCancellation(
        taskID: UUID,
        history: [VideoAnalyzerFixtureHistoryRecord],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let terminals = history.filter { $0.kind == "terminal" && $0.taskID == taskID }
        XCTAssertEqual(terminals.count, 1, file: file, line: line)
        XCTAssertEqual(terminals.first?.status, "cancelled", file: file, line: line)
        let path = "/jobs/\(taskID.uuidString.lowercased())"
        XCTAssertEqual(history.filter {
            $0.kind == "request" && $0.method == "DELETE" && $0.path?.hasSuffix(path) == true
        }.count, 1, file: file, line: line)
    }
}
