import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginVideoAnalyzerSuccessE2ETests: XCTestCase {
    func testChunkedSSEReconnectsAndValidatesFileBackedArtifact() async throws {
        let repository = try RealHTTPVideoAnalyzerTestSupport.repository()
        let workspace = try RealHTTPVideoAnalyzerWorkspace(label: "success")
        var options = VideoAnalyzerFixtureOptions()
        options.sseChunkBytes = 7
        options.sseDisconnectAfterEvent = 1
        let fixture = try VideoAnalyzerFixtureProcess(repository: repository, root: workspace.root, options: options)
        defer {
            RealHTTPVideoAnalyzerTestSupport.assertClean(fixture.stop())
            workspace.remove()
        }
        let taskID = UUID()
        let recorder = RealHTTPEventRecorder()
        let (runner, _) = try RealHTTPVideoAnalyzerTestSupport.configuredRunner(fixture: fixture)
        let request = RealHTTPVideoAnalyzerTestSupport.request(
            taskID: taskID, fixture: fixture, workspace: workspace,
            config: ["fixtureScenario": "success", "useJoyTag": "false"],
            onEvent: recorder.append
        )

        let run = try await runner.run(request)

        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.events, recorder.events())
        let progress = run.events.compactMap { event -> PluginProgress? in
            if case .progress(let value) = event { value } else { nil }
        }
        XCTAssertEqual(progress.map(\.phase), [
            "sceneDetection", "keyframeExtraction", "keyframeExtraction", "reportGeneration"
        ])
        XCTAssertEqual(progress.map(\.completed), [1, 1, 2, 1])
        XCTAssertEqual(progress.map(\.total), [1, 2, 2, 1])
        XCTAssertEqual(progress.map(\.unit), ["scenes", "frames", "frames", "reports"])
        XCTAssertEqual(run.events.last?.resultStatus, "success")

        let history = try fixture.history()
        let chunkSizes = history.filter { $0.kind == "sseWrite" }.flatMap { $0.chunkSizes ?? [] }
        XCTAssertFalse(chunkSizes.isEmpty, "Fixture history must independently record raw SSE writes.")
        XCTAssertTrue(chunkSizes.allSatisfy { (1 ... 7).contains($0) },
                      "Server writes must stay at or below seven bytes; URLSession may coalesce TCP delivery.")
        XCTAssertTrue(chunkSizes.contains(7), "At least one full seven-byte server write must occur.")
        XCTAssertEqual(history.filter { $0.kind == "sseDisconnect" }.map(\.eventID), [1])
        let eventRequests = history.filter { $0.kind == "request" && $0.path?.hasSuffix("/events") == true }
        XCTAssertEqual(eventRequests.map(\.lastEventID), [0, 1])
        XCTAssertEqual(history.filter { $0.kind == "submission" }.map(\.taskID), [taskID])
        XCTAssertEqual(history.first { $0.kind == "submission" }?.config?["useJoyTag"], "false")

        let artifact = try XCTUnwrap(run.events.compactMap { event -> PluginFileArtifact? in
            guard case .result(_, _, _, let artifacts) = event else { return nil }
            return artifacts.compactMap(\.file).first
        }.first)
        let data = try Data(contentsOf: workspace.output.appendingPathComponent(artifact.relativePath))
        XCTAssertEqual(data.count, artifact.byteCount)
    }

    func testCapabilitiesWithoutSSEUseRealPollingAndNeverOpenEventStream() async throws {
        let repository = try RealHTTPVideoAnalyzerTestSupport.repository()
        let workspace = try RealHTTPVideoAnalyzerWorkspace(label: "polling")
        var options = VideoAnalyzerFixtureOptions()
        options.disableSSE = true
        let fixture = try VideoAnalyzerFixtureProcess(repository: repository, root: workspace.root, options: options)
        defer {
            RealHTTPVideoAnalyzerTestSupport.assertClean(fixture.stop())
            workspace.remove()
        }
        let taskID = UUID()
        let (runner, _) = try RealHTTPVideoAnalyzerTestSupport.configuredRunner(fixture: fixture)

        let run = try await runner.run(RealHTTPVideoAnalyzerTestSupport.request(
            taskID: taskID, fixture: fixture, workspace: workspace,
            config: ["fixtureScenario": "success", "fixtureDelayMilliseconds": "80"]
        ))

        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.events.last?.resultStatus, "success")
        let history = try fixture.history()
        XCTAssertFalse(history.contains { $0.path?.hasSuffix("/events") == true })
        XCTAssertTrue(history.contains {
            $0.kind == "request" && $0.method == "GET"
                && $0.path?.hasSuffix("/jobs/\(taskID.uuidString.lowercased())") == true
        })
        XCTAssertTrue(history.contains { $0.path?.hasSuffix("/result") == true })
    }

}

private extension PluginArtifact {
    var file: PluginFileArtifact? {
        if case .file(let value) = payload { value } else { nil }
    }
}
