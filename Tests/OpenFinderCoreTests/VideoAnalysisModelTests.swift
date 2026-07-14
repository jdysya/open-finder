import Foundation
import XCTest
@testable import OpenFinderCore

final class VideoAnalysisModelTests: XCTestCase {
    func testRequestRoundTripsThroughJSON() throws {
        let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let request = VideoAnalysisRequest(
            taskID: taskID,
            files: [.init(path: "/tmp/demo.mp4", name: "demo.mp4")],
            options: .init(useJoyTag: true),
            outputDirectory: "/tmp/output"
        )

        let data = try JSONEncoder.openFinder.encode(request)
        let decoded = try JSONDecoder.openFinder.decode(VideoAnalysisRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testParserDecodesProgressEvent() throws {
        let line = #"{"schemaVersion":1,"type":"progress","taskID":"11111111-1111-1111-1111-111111111111","videoPath":"/tmp/demo.mp4","stage":"keyframeExtraction","detail":"3 frames","fraction":0.25}"#

        let event = try VideoAnalysisWorkerEventParser.parse(line: line)

        XCTAssertEqual(
            event,
            .progress(.init(
                taskID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                videoPath: "/tmp/demo.mp4",
                stage: .keyframeExtraction,
                detail: "3 frames",
                fraction: 0.25
            ))
        )
    }

    func testParserDecodesResultEvent() throws {
        let line = #"{"schemaVersion":1,"type":"result","result":{"schemaVersion":1,"taskID":"11111111-1111-1111-1111-111111111111","videos":[{"path":"/tmp/demo.mp4","name":"demo.mp4","summary":{"totalFrames":1,"faceVisible":1,"explicit":0,"moderate":0,"partial":0,"none":1},"frames":[],"suggestedTags":[],"reportPath":null}]}}"#

        let event = try VideoAnalysisWorkerEventParser.parse(line: line)

        guard case .result(let result) = event else {
            return XCTFail("Expected result event")
        }
        XCTAssertEqual(result.videos.single?.name, "demo.mp4")
        XCTAssertEqual(result.videos.single?.summary.totalFrames, 1)
    }

    func testParserRejectsUnsupportedSchemaVersion() {
        let line = #"{"schemaVersion":2,"type":"log","level":"info","message":"hello"}"#

        XCTAssertThrowsError(try VideoAnalysisWorkerEventParser.parse(line: line)) { error in
            XCTAssertEqual(error as? VideoAnalysisProtocolError, .unsupportedSchemaVersion(2))
        }
    }

    func testParserRejectsProgressWithoutFraction() {
        let line = #"{"schemaVersion":1,"type":"progress","taskID":"11111111-1111-1111-1111-111111111111","videoPath":"/tmp/demo.mp4","stage":"sceneDetection","detail":"working"}"#

        XCTAssertThrowsError(try VideoAnalysisWorkerEventParser.parse(line: line)) { error in
            XCTAssertEqual(error as? VideoAnalysisProtocolError, .missingField("fraction"))
        }
    }

    func testParserRejectsUnknownEventType() {
        let line = #"{"schemaVersion":1,"type":"mystery"}"#

        XCTAssertThrowsError(try VideoAnalysisWorkerEventParser.parse(line: line)) { error in
            XCTAssertEqual(error as? VideoAnalysisProtocolError, .unknownEventType("mystery"))
        }
    }

    func testPluginArtifactDecodesOnlyMatchingTaskResult() throws {
        let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let result = VideoAnalysisResult(taskID: taskID, videos: [])
        let artifact = PluginArtifact(
            type: "videoAnalysisResult",
            content: String(decoding: try JSONEncoder.openFinder.encode(result), as: UTF8.self)
        )

        let decoded = try VideoAnalysisPluginResultDecoder.decode(
            from: [.result(status: "success", message: nil, clipboard: nil, artifacts: [artifact])],
            expectedTaskID: taskID
        )

        XCTAssertEqual(decoded, result)
    }

    func testPluginArtifactRejectsMismatchedTaskResult() throws {
        let artifact = PluginArtifact(
            type: "videoAnalysisResult",
            content: String(decoding: try JSONEncoder.openFinder.encode(VideoAnalysisResult(taskID: UUID(), videos: [])), as: UTF8.self)
        )

        XCTAssertThrowsError(try VideoAnalysisPluginResultDecoder.decode(
            from: [.result(status: "success", message: nil, clipboard: nil, artifacts: [artifact])],
            expectedTaskID: UUID()
        )) { error in
            XCTAssertEqual(error as? VideoAnalysisPluginResultError, .taskIDMismatch)
        }
    }
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
