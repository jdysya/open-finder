import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginWireTests: XCTestCase {
    func testDecodesNegotiationAndSnapshotShapes() throws {
        let health = try HTTPPluginWire.health(data(#"{"schemaVersion":1,"protocolVersion":1,"status":"ready","pluginID":"dev.openfinder.plugins.video-analyzer","pluginVersion":"0.1.0","runtime":{"name":"Python","version":"3.12"},"checks":[]}"#))
        XCTAssertEqual(health.status, "ready")
        XCTAssertEqual(health.runtime?.version, "3.12")

        let capabilities = try HTTPPluginWire.capabilities(data(Self.capabilities))
        XCTAssertTrue(capabilities.features.sse)
        XCTAssertTrue(capabilities.features.polling)

        let snapshot = try HTTPPluginWire.snapshot(data(Self.snapshot), taskID: HTTPPluginTestFixture.taskID)
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.progress?.eventID, 3)
    }

    func testRejectsUnknownFieldsSchemaIdentityAndMalformedProgress() {
        assertInvalid { try HTTPPluginWire.health(self.data(#"{"schemaVersion":1,"protocolVersion":1,"status":"ready","extra":true}"#)) }
        assertInvalid { try HTTPPluginWire.health(self.data(#"{"schemaVersion":2,"protocolVersion":1,"status":"ready"}"#)) }
        assertInvalid { try HTTPPluginWire.capabilities(self.data(Self.capabilities.replacingOccurrences(of: #""protocolVersion":1"#, with: #""protocolVersion":2"#))) }
        assertInvalid { try HTTPPluginWire.snapshot(self.data(Self.snapshot.replacingOccurrences(of: #""fraction":0.5"#, with: #""fraction":2"#)), taskID: HTTPPluginTestFixture.taskID) }
        assertInvalid { try HTTPPluginWire.snapshot(self.data(Self.snapshot), taskID: UUID()) }
    }

    func testDecodesTerminalResultWithStrictEventValidation() throws {
        let result = try HTTPPluginWire.result(data(Self.result), taskID: HTTPPluginTestFixture.taskID)
        XCTAssertEqual(result.eventID, 4)
        XCTAssertEqual(result.pluginOutputEvent.resultStatus, "success")

        assertInvalid {
            try HTTPPluginWire.result(self.data(Self.result.replacingOccurrences(of: #""taskID":"11111111-1111-1111-1111-111111111111"#, with: #""taskID":"22222222-2222-2222-2222-222222222222"#)), taskID: HTTPPluginTestFixture.taskID)
        }
    }

    func testErrorEnvelopeIsStrictAndRedactsToken() {
        let token = "fixture-secret-token"
        let error = HTTPPluginWire.serverError(data(#"{"schemaVersion":1,"code":"internal_error","message":"failed fixture-secret-token","retryable":true}"#), status: 500, token: token)
        XCTAssertEqual(error, .server(status: 500, code: "internal_error", message: "failed REDACTED", retryable: true))
        XCTAssertFalse(error.localizedDescription.contains(token))

        XCTAssertEqual(HTTPPluginWire.serverError(data(#"{"schemaVersion":1,"code":"x","message":"x","retryable":false,"extra":1}"#), status: 400, token: token), .invalidResponse("error envelope"))
    }

    private func data(_ value: String) -> Data { Data(value.utf8) }
    private func assertInvalid<T>(_ body: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line)
    }

    private static let capabilities = #"{"schemaVersion":1,"protocolVersion":1,"pluginID":"dev.openfinder.plugins.video-analyzer","pluginVersion":"0.1.0","actions":[{"id":"analyze-video"}],"features":{"sse":true,"polling":true,"cancellation":true,"fileArtifacts":true},"limits":{"maxRequestBytes":1048576,"terminalRetentionSeconds":1800,"maxEventsPerJob":10000,"maxQueuedJobs":100}}"#

    private static let snapshot = #"{"schemaVersion":1,"taskID":"11111111-1111-1111-1111-111111111111","state":"running","createdAt":"2026-07-16T00:00:00Z","updatedAt":"2026-07-16T00:00:01Z","startedAt":"2026-07-16T00:00:01Z","finishedAt":null,"lastEventID":3,"resultAvailable":false,"progress":{"schemaVersion":1,"eventID":3,"taskID":"11111111-1111-1111-1111-111111111111","type":"progress","fraction":0.5,"completed":1,"total":2,"unit":"frames"}}"#

    private static let result = #"{"schemaVersion":1,"eventID":4,"taskID":"11111111-1111-1111-1111-111111111111","type":"result","status":"success","artifacts":[]}"#
}
