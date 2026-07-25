import Foundation
import XCTest
@testable import OpenFinderCore

final class ServerSentEventParserTests: XCTestCase {
    private let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func testParsesWholeGoldenStreamAndMapsPluginEvents() throws {
        var parser = ServerSentEventParser(expectedTaskID: taskID)

        let events = try parser.append(Data(Self.goldenStream.utf8))
        try parser.finish()

        XCTAssertEqual(events.map(\.eventID), [1, 3, 7])
        XCTAssertEqual(events.map(\.type), [.log, .progress, .result])
        XCTAssertEqual(events.map(\.pluginOutputEvent), [
            .log(level: "info", message: "Preparing"),
            .progress(.init(
                fraction: 0.375,
                message: "3/8 frames",
                phase: "Keyframe extraction",
                completed: 3,
                total: 8,
                unit: "frames"
            )),
            .result(
                status: "success",
                message: "Analyzed 1 video.",
                clipboard: nil,
                artifacts: [PluginArtifact(type: "mediaAnalysis.v1", file: PluginFileArtifact(
                    artifactID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                    relativePath: "result.json",
                    mediaType: "application/json",
                    byteCount: 2_048,
                    sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                ))]
            )
        ])
        XCTAssertEqual(events.last?.artifacts, [
            .init(
                type: "mediaAnalysis.v1",
                relativePath: "result.json",
                mediaType: "application/json",
                byteCount: 2_048,
                sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                artifactID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
            )
        ])
        XCTAssertEqual(parser.lastEventID, 7)
        XCTAssertTrue(parser.hasReceivedTerminalEvent)
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testByteByByteAndSeededRandomChunksMatchWholeStream() throws {
        let bytes = Data(try canonicalOpenAPIReplay().utf8)
        let expected = try parse(chunks: [bytes])

        XCTAssertEqual(expected.map(\.eventID), [3, 7])
        XCTAssertEqual(expected.map(\.type), [.progress, .result])

        let bytewise = try parse(chunks: bytes.map { Data([$0]) })
        XCTAssertEqual(bytewise, expected)

        for seed in 1 ... 40 {
            var generator = SeededGenerator(seed: UInt64(seed))
            var chunks: [Data] = []
            var offset = 0
            while offset < bytes.count {
                let length = min(Int(generator.next() % 47) + 1, bytes.count - offset)
                chunks.append(bytes.subdata(in: offset ..< offset + length))
                offset += length
            }
            XCTAssertEqual(try parse(chunks: chunks), expected, "seed \(seed)")
        }
    }

    func testAcceptsCRLFHeartbeatsAndMultilineData() throws {
        let stream = """
        : heartbeat\r
        \r
        id: 1\r
        event: log\r
        data: {"schemaVersion":1,\r
        data: "eventID":1,"taskID":"11111111-1111-1111-1111-111111111111","type":"log","level":"debug","message":"split"}\r
        \r
        id: 2\r
        event: result\r
        data: {"schemaVersion":1,"eventID":2,"taskID":"11111111-1111-1111-1111-111111111111","type":"result","status":"cancelled","artifacts":[]}\r
        \r

        """

        let events = try parse(chunks: [Data(stream.utf8)])

        XCTAssertEqual(events.map(\.pluginOutputEvent), [
            .log(level: "debug", message: "split"),
            .result(status: "cancelled", message: nil, clipboard: nil, artifacts: [])
        ])
    }

    func testPreservesUnicodeSplitAcrossIndividualByteChunks() throws {
        let log = #"{"schemaVersion":1,"eventID":1,"taskID":"11111111-1111-1111-1111-111111111111","type":"log","level":"info","message":"准备 🎬"}"#
        let stream = frame(eventID: 1, event: "log", json: log) + Self.resultFrame(eventID: 2)

        let events = try parse(chunks: Data(stream.utf8).map { Data([$0]) })

        XCTAssertEqual(events.first?.pluginOutputEvent, .log(level: "info", message: "准备 🎬"))
    }

    func testReconnectCursorAcceptsOnlyGreaterIDs() throws {
        var parser = ServerSentEventParser(expectedTaskID: taskID, lastEventID: 6)

        let events = try parser.append(Data(Self.resultFrame(eventID: 7).utf8))
        try parser.finish()

        XCTAssertEqual(events.map(\.eventID), [7])
        XCTAssertEqual(parser.lastEventID, 7)
    }

    func testResultArtifactPreservesServerArtifactID() throws {
        let artifactID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let json = """
        {"schemaVersion":1,"eventID":1,"taskID":"\(taskID.uuidString)","type":"result","status":"success","artifacts":[{"artifactID":"\(artifactID.uuidString)","type":"mediaAnalysis.v1","relativePath":"result.json","mediaType":"application/json","byteCount":2048,"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}]}
        """
        var parser = ServerSentEventParser(expectedTaskID: taskID)

        let events = try parser.append(Data(frame(eventID: 1, event: "result", json: json).utf8))
        try parser.finish()

        guard case .result(_, _, _, let artifacts) = events.first?.pluginOutputEvent else {
            return XCTFail("Expected terminal result event.")
        }
        XCTAssertEqual(artifacts.first?.file?.artifactID, artifactID)
    }

    func testMediaResultArtifactWithoutArtifactIDIsRejected() {
        let json = """
        {"schemaVersion":1,"eventID":1,"taskID":"\(taskID.uuidString)","type":"result","status":"success","artifacts":[{"type":"mediaAnalysis.v1","relativePath":"result.json","mediaType":"application/json","byteCount":2048,"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}]}
        """
        var parser = ServerSentEventParser(expectedTaskID: taskID)

        XCTAssertThrowsError(
            try parser.append(Data(frame(eventID: 1, event: "result", json: json).utf8))
        ) { error in
            XCTAssertEqual(
                error as? ServerSentEventParserError,
                .invalidEvent(field: "artifacts.artifactID")
            )
        }
    }

    func testRejectsEventLargerThanOneMiBWithoutGrowingPastLimit() {
        var parser = ServerSentEventParser(expectedTaskID: taskID)
        var oversized = Data("data: ".utf8)
        oversized.append(Data(repeating: 0x61, count: ServerSentEventParser.maximumEventBytes))

        XCTAssertThrowsError(try parser.append(oversized)) { error in
            XCTAssertEqual(
                error as? ServerSentEventParserError,
                .eventTooLarge(limit: ServerSentEventParser.maximumEventBytes)
            )
        }
        XCTAssertLessThanOrEqual(parser.bufferedByteCount, ServerSentEventParser.maximumEventBytes)
    }

    func testRejectsInvalidUTF8AndLatchesFailure() {
        var bytes = Data("id: 1\nevent: log\ndata: ".utf8)
        bytes.append(0xff)
        bytes.append(Data("\n\n".utf8))
        var parser = ServerSentEventParser(expectedTaskID: taskID)

        XCTAssertThrowsError(try parser.append(bytes)) { error in
            XCTAssertEqual(error as? ServerSentEventParserError, .invalidUTF8)
        }
        XCTAssertThrowsError(try parser.append(Data(Self.goldenStream.utf8))) { error in
            XCTAssertEqual(error as? ServerSentEventParserError, .parserAlreadyFailed)
        }
    }

    func testRejectsNonNumericNegativeZeroAndRegressedEventIDs() throws {
        for invalidID in ["abc", "-1", "0", "+1"] {
            var parser = ServerSentEventParser(expectedTaskID: taskID)
            let stream = "id: \(invalidID)\nevent: log\ndata: {}\n\n"
            XCTAssertThrowsError(try parser.append(Data(stream.utf8)), invalidID) { error in
                XCTAssertEqual(error as? ServerSentEventParserError, .invalidEventID(invalidID))
            }
        }

        var parser = ServerSentEventParser(expectedTaskID: taskID)
        _ = try parser.append(Data(Self.logFrame(eventID: 2).utf8))
        XCTAssertThrowsError(try parser.append(Data(Self.logFrame(eventID: 1).utf8))) { error in
            XCTAssertEqual(
                error as? ServerSentEventParserError,
                .nonMonotonicEventID(previous: 2, current: 1)
            )
        }
    }

    private func parse(chunks: [Data]) throws -> [HTTPPluginEvent] {
        var parser = ServerSentEventParser(expectedTaskID: taskID)
        var events: [HTTPPluginEvent] = []
        for chunk in chunks {
            events.append(contentsOf: try parser.append(chunk))
        }
        try parser.finish()
        return events
    }

    private func canonicalOpenAPIReplay() throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/plugins/http-plugin-v1.openapi.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let components = try XCTUnwrap(root["components"] as? [String: Any])
        let examples = try XCTUnwrap(components["examples"] as? [String: Any])
        let replay = try XCTUnwrap(examples["SSEReplay"] as? [String: Any])
        return try XCTUnwrap(replay["value"] as? String)
    }

    private func assertAppendError(
        _ stream: String,
        equals expected: ServerSentEventParserError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var parser = ServerSentEventParser(expectedTaskID: taskID)
        XCTAssertThrowsError(try parser.append(Data(stream.utf8)), file: file, line: line) { error in
            XCTAssertEqual(error as? ServerSentEventParserError, expected, file: file, line: line)
        }
    }

    private func frame(eventID: Int, event: String, json: some StringProtocol) -> String {
        "id: \(eventID)\nevent: \(event)\ndata: \(json)\n\n"
    }

    private static func logFrame(eventID: Int) -> String {
        "id: \(eventID)\nevent: log\ndata: \(logJSON(eventID: eventID))\n\n"
    }

    private static func logJSON(
        eventID: Int,
        taskID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        schemaVersion: Int = 1
    ) -> String {
        #"{"schemaVersion":\#(schemaVersion),"eventID":\#(eventID),"taskID":"\#(taskID.uuidString)","type":"log","level":"info","message":"event \#(eventID)"}"#
    }

    private static func resultFrame(eventID: Int) -> String {
        """
        id: \(eventID)
        event: result
        data: {"schemaVersion":1,"eventID":\(eventID),"taskID":"11111111-1111-1111-1111-111111111111","type":"result","status":"success","artifacts":[]}


        """
    }

    private static let goldenStream = """
    id: 1
    event: log
    data: {"schemaVersion":1,"eventID":1,"taskID":"11111111-1111-1111-1111-111111111111","type":"log","level":"info","message":"Preparing"}

    : keep-alive

    id: 3
    event: progress
    data: {"schemaVersion":1,"eventID":3,"taskID":"11111111-1111-1111-1111-111111111111","type":"progress","fraction":0.375,"message":"3/8 frames","phase":"Keyframe extraction","completed":3,"total":8,"unit":"frames"}

    id: 7
    event: result
    data: {"schemaVersion":1,"eventID":7,"taskID":"11111111-1111-1111-1111-111111111111","type":"result","status":"success","message":"Analyzed 1 video.","artifacts":[{"artifactID":"22222222-2222-4222-8222-222222222222","type":"mediaAnalysis.v1","relativePath":"result.json","mediaType":"application/json","byteCount":2048,"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}]}


    """
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
