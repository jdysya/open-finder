import CryptoKit
import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginVideoAnalyzerSuccessE2ETests: XCTestCase {
    func testChunkedSSEReconnectsAndPersistsFileBackedVideoAnalysis() async throws {
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

        try await assertArtifactPersistence(run: run, taskID: taskID, workspace: workspace)
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

    private func assertArtifactPersistence(
        run: PluginRunResult,
        taskID: UUID,
        workspace: RealHTTPVideoAnalyzerWorkspace
    ) async throws {
        let file = try XCTUnwrap(run.events.compactMap { event -> PluginFileArtifact? in
            guard case .result(_, _, _, let artifacts) = event else { return nil }
            return artifacts.first { $0.type == "videoAnalysisResult" }?.file
        }.first)
        let resultData = try Data(contentsOf: workspace.output.appendingPathComponent(file.relativePath))
        XCTAssertEqual(resultData.count, file.byteCount)
        XCTAssertEqual(Self.sha256(resultData), file.sha256)
        let decoded = try VideoAnalysisPluginResultDecoder.decode(
            from: run.events, expectedTaskID: taskID, expectedOutputDirectory: workspace.output
        )
        let sourceFrame = try Data(contentsOf: URL(fileURLWithPath: decoded.videos[0].frames[0].imagePath))
        let sourceReport = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(decoded.videos[0].reportPath)))
        XCTAssertEqual(Array(sourceFrame.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let store = VideoAnalysisResultStore(directory: workspace.store)
        let persisted = try await store.persistConfinedAssets(
            in: decoded, from: ConfinedArtifactReader(root: workspace.output)
        )
        let fingerprint = VideoFileFingerprint(
            canonicalPath: workspace.video.path, size: Int64(try Data(contentsOf: workspace.video).count),
            modificationDate: Date(timeIntervalSince1970: 1), analyzerVersion: "fixture"
        )
        try await store.save(.init(fingerprint: fingerprint, result: persisted, analyzedAt: Date()))
        try FileManager.default.removeItem(at: workspace.taskRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.taskRoot.path))
        let reopened = try await VideoAnalysisResultStore(directory: workspace.store).load(for: fingerprint)?.result
        let frame = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(reopened?.videos[0].frames[0].imagePath)))
        let report = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(reopened?.videos[0].reportPath)))
        XCTAssertEqual(Self.sha256(frame), Self.sha256(sourceFrame))
        XCTAssertEqual(Self.sha256(report), Self.sha256(sourceReport))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension PluginArtifact {
    var file: PluginFileArtifact? {
        if case .file(let value) = payload { value } else { nil }
    }
}
