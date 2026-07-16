import Foundation
import XCTest
@testable import OpenFinderCore

final class ServerSentEventValidationTests: XCTestCase {
    private let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func testRejectsWrongTaskSchemaAndMismatchedSSEMetadata() {
        let otherTaskID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        assertAppendError(
            frame(eventID: 1, event: "log", json: Self.logJSON(eventID: 1, taskID: otherTaskID)),
            equals: .taskIDMismatch(expected: taskID, actual: otherTaskID)
        )
        assertAppendError(frame(eventID: 1, event: "log", json: Self.logJSON(eventID: 1, schemaVersion: 2)), equals: .unsupportedSchemaVersion(2))
        assertAppendError(frame(eventID: 1, event: "log", json: Self.logJSON(eventID: 2)), equals: .eventIDMismatch(sse: 1, json: 2))
        assertAppendError(frame(eventID: 1, event: "progress", json: Self.logJSON(eventID: 1)), equals: .eventTypeMismatch(sse: "progress", json: "log"))
    }

    func testRejectsMalformedJSONUnknownFieldsAndInvalidProgressShape() {
        assertAppendError(frame(eventID: 1, event: "log", json: "{"), equals: .invalidJSON)
        assertAppendError(
            frame(eventID: 1, event: "log", json: Self.logJSON(eventID: 1).dropLast() + #", "unexpected":true}"#),
            equals: .invalidEvent(field: "unexpected")
        )
        let invalidProgress = #"{"schemaVersion":1,"eventID":1,"taskID":"11111111-1111-1111-1111-111111111111","type":"progress","fraction":1.1}"#
        assertAppendError(frame(eventID: 1, event: "progress", json: invalidProgress), equals: .invalidEvent(field: "fraction"))
        let invalidCounts = #"{"schemaVersion":1,"eventID":1,"taskID":"11111111-1111-1111-1111-111111111111","type":"progress","fraction":0.5,"completed":2}"#
        assertAppendError(frame(eventID: 1, event: "progress", json: invalidCounts), equals: .invalidEvent(field: "completed/total"))
        let nullOptional = #"{"schemaVersion":1,"eventID":1,"taskID":"11111111-1111-1111-1111-111111111111","type":"progress","fraction":0.5,"message":null}"#
        assertAppendError(frame(eventID: 1, event: "progress", json: nullOptional), equals: .invalidEvent(field: "message"))
    }

    func testRejectsInvalidFileArtifactMetadata() {
        let json = #"{"schemaVersion":1,"eventID":1,"taskID":"11111111-1111-1111-1111-111111111111","type":"result","status":"success","artifacts":[{"type":"result","relativePath":"../result.json","mediaType":"application/json","byteCount":1,"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}]}"#
        assertAppendError(frame(eventID: 1, event: "result", json: json), equals: .invalidEvent(field: "artifacts.relativePath"))
    }

    func testRejectsDuplicateTerminalAndAnyEventAfterTerminal() throws {
        var duplicate = ServerSentEventParser(expectedTaskID: taskID)
        _ = try duplicate.append(Data(Self.resultFrame(eventID: 1).utf8))
        XCTAssertThrowsError(try duplicate.append(Data(Self.resultFrame(eventID: 2).utf8))) {
            XCTAssertEqual($0 as? ServerSentEventParserError, .duplicateTerminalEvent)
        }
        var afterTerminal = ServerSentEventParser(expectedTaskID: taskID)
        _ = try afterTerminal.append(Data(Self.resultFrame(eventID: 1).utf8))
        XCTAssertThrowsError(try afterTerminal.append(Data(Self.logFrame(eventID: 2).utf8))) {
            XCTAssertEqual($0 as? ServerSentEventParserError, .eventAfterTerminal)
        }
    }

    func testFinishRejectsTruncatedOrNonterminalStreams() throws {
        var truncated = ServerSentEventParser(expectedTaskID: taskID)
        _ = try truncated.append(Data("id: 1\nevent: log\ndata: {}\n".utf8))
        XCTAssertThrowsError(try truncated.finish()) { XCTAssertEqual($0 as? ServerSentEventParserError, .truncatedEvent) }
        var nonterminal = ServerSentEventParser(expectedTaskID: taskID)
        _ = try nonterminal.append(Data(Self.logFrame(eventID: 1).utf8))
        XCTAssertThrowsError(try nonterminal.finish()) { XCTAssertEqual($0 as? ServerSentEventParserError, .missingTerminalEvent) }
    }

    private func assertAppendError(_ stream: String, equals expected: ServerSentEventParserError) {
        var parser = ServerSentEventParser(expectedTaskID: taskID)
        XCTAssertThrowsError(try parser.append(Data(stream.utf8))) {
            XCTAssertEqual($0 as? ServerSentEventParserError, expected)
        }
    }

    private func frame(eventID: Int, event: String, json: some StringProtocol) -> String {
        "id: \(eventID)\nevent: \(event)\ndata: \(json)\n\n"
    }

    private static func logFrame(eventID: Int) -> String {
        "id: \(eventID)\nevent: log\ndata: \(logJSON(eventID: eventID))\n\n"
    }

    private static func logJSON(eventID: Int, taskID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, schemaVersion: Int = 1) -> String {
        #"{"schemaVersion":\#(schemaVersion),"eventID":\#(eventID),"taskID":"\#(taskID.uuidString)","type":"log","level":"info","message":"event \#(eventID)"}"#
    }

    private static func resultFrame(eventID: Int) -> String {
        "id: \(eventID)\nevent: result\ndata: {\"schemaVersion\":1,\"eventID\":\(eventID),\"taskID\":\"11111111-1111-1111-1111-111111111111\",\"type\":\"result\",\"status\":\"success\",\"artifacts\":[]}\n\n"
    }
}
