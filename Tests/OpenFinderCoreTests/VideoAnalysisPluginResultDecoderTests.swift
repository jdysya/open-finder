import CryptoKit
import Foundation
import XCTest
@testable import OpenFinderCore

final class VideoAnalysisPluginResultDecoderTests: XCTestCase {
    private let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func testLegacyInlineResultKeepsAbsoluteAssetPaths() throws {
        let result = makeResult(imagePath: "/legacy/frame.jpg", reportPath: "/legacy/report.html")
        let event = inlineEvent(result)

        let decoded = try VideoAnalysisPluginResultDecoder.decode(from: [event], expectedTaskID: taskID)

        XCTAssertEqual(decoded, result)
    }

    func testFileResultValidatesAndNormalizesNestedAssets() throws {
        try withWorkspace { root in
            try write(Data("frame".utf8), at: "frames/frame.jpg", root: root)
            try write(Data("<img src=\"../frames/frame.jpg\">".utf8), at: "reports/report.html", root: root)
            let result = makeResult(imagePath: "frames/frame.jpg", reportPath: "reports/report.html")

            let decoded = try VideoAnalysisPluginResultDecoder.decode(
                from: [try fileEvent(result, root: root)],
                expectedTaskID: taskID,
                expectedOutputDirectory: root
            )

            XCTAssertEqual(decoded.videos[0].frames[0].imagePath, root.appendingPathComponent("frames/frame.jpg").path)
            XCTAssertEqual(decoded.videos[0].reportPath, root.appendingPathComponent("reports/report.html").path)
        }
    }

    func testRejectsWrongArtifactCountTypeSchemaAndTask() throws {
        try withWorkspace { root in
            let valid = try fileEvent(makeResult(imagePath: "frame.jpg", reportPath: nil), root: root)
            XCTAssertThrowsError(try decode([], root: root)) { XCTAssertEqual($0 as? VideoAnalysisPluginResultError, .missingResultArtifact) }
            XCTAssertThrowsError(try decode([valid, valid], root: root)) { XCTAssertEqual($0 as? VideoAnalysisPluginResultError, .missingResultArtifact) }
            let wrongType = try event(type: "other", result: makeResult(imagePath: "frame.jpg", reportPath: nil), root: root)
            XCTAssertThrowsError(try decode([wrongType], root: root)) { XCTAssertEqual($0 as? VideoAnalysisPluginResultError, .missingResultArtifact) }
            let wrongSchema = makeResult(schemaVersion: 2, imagePath: "frame.jpg", reportPath: nil)
            XCTAssertThrowsError(try decode([try fileEvent(wrongSchema, root: root)], root: root)) {
                XCTAssertEqual($0 as? VideoAnalysisPluginResultError, .unsupportedSchemaVersion(2))
            }
            let wrongTask = VideoAnalysisResult(taskID: UUID(), videos: [])
            XCTAssertThrowsError(try decode([try fileEvent(wrongTask, root: root)], root: root)) {
                XCTAssertEqual($0 as? VideoAnalysisPluginResultError, .taskIDMismatch)
            }
        }
    }

    func testRejectsAbsoluteTraversalMissingAndSymlinkNestedAssets() throws {
        try withWorkspace { root in
            let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: outside) }
            try Data("outside".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.jpg"), withDestinationURL: outside)
            for path in ["/absolute.jpg", "../escape.jpg", "missing.jpg", "link.jpg"] {
                let event = try fileEvent(makeResult(imagePath: path, reportPath: nil), root: root)
                XCTAssertThrowsError(try decode([event], root: root), "Expected rejection for \(path)") { error in
                    guard case .invalidNestedAsset = error as? VideoAnalysisPluginResultError else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
    }

    func testHTTPMetadataReachesPluginOutputEvent() throws {
        let json = #"{"schemaVersion":1,"eventID":1,"taskID":"11111111-1111-1111-1111-111111111111","type":"result","status":"success","artifacts":[{"type":"videoAnalysisResult","relativePath":"result.json","mediaType":"application/json","byteCount":2,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}"#
        let event = try HTTPPluginEvent.decode(Data(json.utf8), sseEventID: 1, sseEventType: "result", expectedTaskID: taskID)
        guard case .result(_, _, _, let artifacts) = event.pluginOutputEvent else { return XCTFail("Expected result") }

        XCTAssertEqual(artifacts.single?.file?.relativePath, "result.json")
        XCTAssertNil(artifacts.single?.content)
    }

    private func decode(_ events: [PluginOutputEvent], root: URL) throws -> VideoAnalysisResult {
        try VideoAnalysisPluginResultDecoder.decode(from: events, expectedTaskID: taskID, expectedOutputDirectory: root)
    }

    private func inlineEvent(_ result: VideoAnalysisResult) -> PluginOutputEvent {
        let data = try! JSONEncoder.openFinder.encode(result)
        return .result(status: "success", message: nil, clipboard: nil, artifacts: [
            .init(type: "videoAnalysisResult", content: String(decoding: data, as: UTF8.self))
        ])
    }

    private func fileEvent(_ result: VideoAnalysisResult, root: URL) throws -> PluginOutputEvent {
        try event(type: "videoAnalysisResult", result: result, root: root)
    }

    private func event(type: String, result: VideoAnalysisResult, root: URL) throws -> PluginOutputEvent {
        let data = try JSONEncoder.openFinder.encode(result)
        try write(data, at: "result.json", root: root)
        let file = PluginFileArtifact(
            relativePath: "result.json", mediaType: "application/json", byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
        return .result(status: "success", message: nil, clipboard: nil, artifacts: [.init(type: type, file: file)])
    }

    private func makeResult(schemaVersion: Int = 1, imagePath: String, reportPath: String?) -> VideoAnalysisResult {
        .init(schemaVersion: schemaVersion, taskID: taskID, videos: [.init(
            path: "/video.mp4", name: "video.mp4",
            summary: .init(totalFrames: 1, faceVisible: 0, explicit: 0, moderate: 0, partial: 0, none: 1),
            frames: [.init(index: 0, timestamp: 0, imagePath: imagePath, faceVisible: false, faceCount: 0, nudityLevel: .none, summary: "", tags: [])],
            suggestedTags: [], reportPath: reportPath
        )])
    }

    private func withWorkspace(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DecoderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ data: Data, at relativePath: String, root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
