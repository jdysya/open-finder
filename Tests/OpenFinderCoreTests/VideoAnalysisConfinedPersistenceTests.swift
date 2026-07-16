import CryptoKit
import Foundation
import XCTest
@testable import OpenFinderCore

final class VideoAnalysisConfinedPersistenceTests: XCTestCase {
    private let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func testConfinedAssetsSurviveWorkspaceDeletionWithRelativeReportLinks() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = try ConfinedArtifactReader(root: fixture.workspace)
        let store = VideoAnalysisResultStore(directory: fixture.store)
        let wireResult = replacingPaths(
            in: fixture.result,
            framePath: "frames/frame.jpg",
            reportPath: "reports/report.html"
        )
        let data = try JSONEncoder.openFinder.encode(wireResult)
        try data.write(to: fixture.workspace.appendingPathComponent("result.json"))
        let metadata = PluginFileArtifact(
            relativePath: "result.json", mediaType: "application/json", byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
        let event = PluginOutputEvent.result(
            status: "success", message: nil, clipboard: nil,
            artifacts: [.init(type: "videoAnalysisResult", file: metadata)]
        )
        let decoded = try VideoAnalysisPluginResultDecoder.decode(
            from: [event], expectedTaskID: taskID, expectedOutputDirectory: fixture.workspace
        )

        let persisted = try await store.persistConfinedAssets(in: decoded, from: reader)
        let fingerprint = VideoFileFingerprint(
            canonicalPath: "/video.mp4", size: 1, modificationDate: Date(timeIntervalSince1970: 1),
            analyzerVersion: "fixture"
        )
        try await store.save(.init(fingerprint: fingerprint, result: persisted, analyzedAt: Date()))
        try FileManager.default.removeItem(at: fixture.workspace)
        let reopened = try await VideoAnalysisResultStore(directory: fixture.store).load(for: fingerprint)?.result

        let framePath = try XCTUnwrap(reopened?.videos[0].frames[0].imagePath)
        let reportPath = try XCTUnwrap(reopened?.videos[0].reportPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: framePath)), Data("frame".utf8))
        let html = try String(contentsOfFile: reportPath, encoding: .utf8)
        XCTAssertEqual(html, #"<img src="../frames/frame.jpg">"#)
        let linkedFrame = URL(fileURLWithPath: reportPath).deletingLastPathComponent()
            .appendingPathComponent("../frames/frame.jpg").standardizedFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkedFrame.path))
        XCTAssertTrue(framePath.contains("assets/\(taskID.uuidString)/frames/frame.jpg"))
    }

    func testConfinedPersistenceRejectsPathOutsideCapturedRoot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outsideResult = replacingFramePath(in: fixture.result, with: "/tmp/outside.jpg")
        let store = VideoAnalysisResultStore(directory: fixture.store)

        await XCTAssertThrowsErrorAsync(
            try await store.persistConfinedAssets(in: outsideResult, from: ConfinedArtifactReader(root: fixture.workspace))
        ) { error in
            XCTAssertEqual(error as? ConfinedArtifactError, .invalidRelativePath)
        }
    }

    func testConfinedPersistenceRefusesSymlinkIntroducedAfterDecode() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let frame = fixture.workspace.appendingPathComponent("frames/frame.jpg")
        let outside = fixture.root.appendingPathComponent("outside.jpg")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: frame)
        try FileManager.default.createSymbolicLink(at: frame, withDestinationURL: outside)
        let store = VideoAnalysisResultStore(directory: fixture.store)

        await XCTAssertThrowsErrorAsync(
            try await store.persistConfinedAssets(in: fixture.result, from: ConfinedArtifactReader(root: fixture.workspace))
        )
    }

    private func makeFixture() throws -> (root: URL, workspace: URL, store: URL, result: VideoAnalysisResult) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConfinedPersistence-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        let store = root.appendingPathComponent("store")
        let frame = workspace.appendingPathComponent("frames/frame.jpg")
        let report = workspace.appendingPathComponent("reports/report.html")
        try FileManager.default.createDirectory(at: frame.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: frame)
        try Data(#"<img src="../frames/frame.jpg">"#.utf8).write(to: report)
        let result = VideoAnalysisResult(taskID: taskID, videos: [.init(
            path: "/video.mp4", name: "video.mp4",
            summary: .init(totalFrames: 1, faceVisible: 0, explicit: 0, moderate: 0, partial: 0, none: 1),
            frames: [.init(index: 0, timestamp: 0, imagePath: frame.path, faceVisible: false, faceCount: 0, nudityLevel: .none, summary: "", tags: [])],
            suggestedTags: [], reportPath: report.path
        )])
        return (root, workspace, store, result)
    }

    private func replacingFramePath(in result: VideoAnalysisResult, with path: String) -> VideoAnalysisResult {
        replacingPaths(in: result, framePath: path, reportPath: result.videos[0].reportPath)
    }

    private func replacingPaths(
        in result: VideoAnalysisResult,
        framePath: String,
        reportPath: String?
    ) -> VideoAnalysisResult {
        let video = result.videos[0]
        let frame = video.frames[0]
        return .init(taskID: result.taskID, videos: [.init(
            path: video.path, name: video.name, summary: video.summary,
            frames: [.init(index: frame.index, timestamp: frame.timestamp, imagePath: framePath, faceVisible: frame.faceVisible, faceCount: frame.faceCount, nudityLevel: frame.nudityLevel, summary: frame.summary, tags: frame.tags)],
            suggestedTags: video.suggestedTags, reportPath: reportPath
        )])
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
