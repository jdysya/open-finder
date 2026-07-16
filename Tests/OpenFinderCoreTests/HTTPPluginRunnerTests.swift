import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginRunnerTests: XCTestCase {
    func testRunsNegotiationSubmissionSSEAndStrictTerminalResult() async throws {
        let transport = Self.makeTransport(stream: { _ in
            let wire = HTTPPluginResponseFixture.frame(HTTPPluginResponseFixture.progress, id: 1, type: "progress")
                + HTTPPluginResponseFixture.frame(HTTPPluginResponseFixture.result, id: 2, type: "result")
            return HTTPPluginResponseFixture.stream([String(wire.prefix(37)), String(wire.dropFirst(37))])
        })
        let observed = EventRecorder()
        var request = HTTPPluginResponseFixture.request()
        request = replacingCallback(request) { observed.append($0) }

        let result = try await runner(transport).run(request)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(observed.count, 2)
        let dataRequests = await transport.capturedDataRequests()
        XCTAssertEqual(dataRequests.map { $0.httpMethod }, ["GET", "GET", "POST", "GET"])
        XCTAssertEqual(dataRequests[0].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        let body = String(decoding: try XCTUnwrap(dataRequests[2].httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("fixture-token"))
        XCTAssertFalse(body.contains("keychain.video.token"))
        let streamRequests = await transport.capturedStreamRequests()
        let streamRequest = try XCTUnwrap(streamRequests.first)
        XCTAssertEqual(streamRequest.value(forHTTPHeaderField: "Last-Event-ID"), "0")
        XCTAssertEqual(streamRequest.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testReconnectsWithCursorAndRequiredBackoff() async throws {
        let sleeps = HTTPPluginSleepRecorder()
        let transport = Self.makeTransport(stream: { index in
            if index == 0 {
                return HTTPPluginResponseFixture.stream([
                    HTTPPluginResponseFixture.frame(HTTPPluginResponseFixture.progress, id: 1, type: "progress")
                ])
            }
            return HTTPPluginResponseFixture.stream([
                HTTPPluginResponseFixture.frame(HTTPPluginResponseFixture.result, id: 2, type: "result")
            ])
        })
        let runner = runner(transport, sleep: { await sleeps.record($0) })

        let result = try await runner.run(HTTPPluginResponseFixture.request())

        XCTAssertEqual(result.events.count, 2)
        let recordedSleeps = await sleeps.captured()
        XCTAssertEqual(recordedSleeps, [0.25])
        let streamRequests = await transport.capturedStreamRequests()
        let cursors = streamRequests.map {
            $0.value(forHTTPHeaderField: "Last-Event-ID")
        }
        XCTAssertEqual(cursors, ["0", "1"])
    }

    func testFallsBackAfterFourCleanDisconnectsAndDeduplicatesPolledProgress() async throws {
        let polls = PollSequence()
        let sleeps = HTTPPluginSleepRecorder()
        let transport = ScriptedHTTPPluginTransport { request, _ in
            try await Self.response(for: request, poll: polls)
        } stream: { _, _ in
            HTTPPluginResponseFixture.stream([])
        }
        let runner = runner(transport, sleep: { await sleeps.record($0) })

        let result = try await runner.run(HTTPPluginResponseFixture.request())

        XCTAssertEqual(result.events, [
            .progress(.init(fraction: 0.5, message: "1/2", completed: 1, total: 2, unit: "frames")),
            .result(status: "success", message: nil, clipboard: nil, artifacts: [])
        ])
        let streamCount = await transport.capturedStreamRequests().count
        let recordedSleeps = await sleeps.captured()
        XCTAssertEqual(streamCount, 4)
        XCTAssertEqual(recordedSleeps, [0.25, 0.5, 1.0, 1.0, 1.0])
    }

    func testMalformedStreamAndExpiredHistoryNeverFallBackToPolling() async throws {
        for stream in [
            HTTPPluginResponseFixture.stream(["id: 1\nevent: log\ndata: {\n\n"]),
            HTTPPluginResponseFixture.stream([
                #"{"schemaVersion":1,"code":"event_history_expired","message":"expired","retryable":false}"#
            ], status: 409, headers: HTTPPluginResponseFixture.headers)
        ] {
            let transport = Self.makeTransport(stream: { _ in stream })
            do {
                _ = try await runner(transport).run(HTTPPluginResponseFixture.request())
                XCTFail("Expected stream failure")
            } catch {
                XCTAssertFalse(error is CancellationError)
            }
            let requests = await transport.capturedDataRequests()
            XCTAssertFalse(requests.contains {
                $0.url?.path.hasSuffix(HTTPPluginTestFixture.taskID.uuidString.lowercased()) == true
                    && $0.httpMethod == "GET"
            })
        }
    }

    func testReconnectsOnlyForRetryableServerFailures() async throws {
        let sleeps = HTTPPluginSleepRecorder()
        let retryable = Self.makeTransport { index in
            if index == 0 {
                return HTTPPluginResponseFixture.stream([
                    #"{"schemaVersion":1,"code":"service_unavailable","message":"retry","retryable":true}"#
                ], status: 503, headers: HTTPPluginResponseFixture.headers)
            }
            return HTTPPluginResponseFixture.stream([
                HTTPPluginResponseFixture.frame(HTTPPluginResponseFixture.result, id: 2, type: "result")
            ])
        }
        _ = try await runner(retryable, sleep: { await sleeps.record($0) })
            .run(HTTPPluginResponseFixture.request())
        let retrySleeps = await sleeps.captured()
        XCTAssertEqual(retrySleeps, [0.25])

        let nonretryable = Self.makeTransport { _ in
            HTTPPluginResponseFixture.stream([
                #"{"schemaVersion":1,"code":"internal_error","message":"stop","retryable":false}"#
            ], status: 500, headers: HTTPPluginResponseFixture.headers)
        }
        do {
            _ = try await self.runner(nonretryable).run(HTTPPluginResponseFixture.request())
            XCTFail("Expected nonretryable server failure")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let requestCount = await nonretryable.capturedStreamRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    private func runner(
        _ transport: ScriptedHTTPPluginTransport,
        sleep: @escaping HTTPPluginSleep = { _ in }
    ) -> HTTPPluginRunner {
        HTTPPluginRunner(transport: transport, credentialResolver: { _ in "fixture-token" }, sleep: sleep)
    }

    private static func makeTransport(
        stream: @escaping @Sendable (Int) async throws -> HTTPPluginStreamResponse
    ) -> ScriptedHTTPPluginTransport {
        ScriptedHTTPPluginTransport { request, _ in
            try await Self.response(for: request, poll: nil)
        } stream: { _, index in
            try await stream(index)
        }
    }

    private static func response(for request: URLRequest, poll: PollSequence?) async throws -> HTTPPluginDataResponse {
        guard let path = request.url?.path else { throw URLError(.badURL) }
        if path.hasSuffix("/health") { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.health) }
        if path.hasSuffix("/capabilities") { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.capabilities()) }
        if request.httpMethod == "POST" { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.snapshot(state: "queued", eventID: 0), status: 202) }
        if path.hasSuffix("/result") { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.result) }
        if request.httpMethod == "GET", let poll { return HTTPPluginResponseFixture.data(await poll.next()) }
        throw URLError(.badServerResponse)
    }

    private func replacingCallback(
        _ request: PluginRunRequest, callback: @escaping @Sendable (PluginOutputEvent) -> Void
    ) -> PluginRunRequest {
        .init(manifest: request.manifest, action: request.action, input: request.input,
              environment: request.environment, pluginDirectory: request.pluginDirectory,
              workingDirectory: request.workingDirectory, onEvent: callback)
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PluginOutputEvent] = []
    func append(_ event: PluginOutputEvent) { lock.withLock { events.append(event) } }
    var count: Int { lock.withLock { events.count } }
}

private actor PollSequence {
    private var index = 0
    func next() -> String {
        defer { index += 1 }
        if index < 2 { return HTTPPluginResponseFixture.snapshot(state: "running", eventID: 1, progress: HTTPPluginResponseFixture.progress) }
        return HTTPPluginResponseFixture.snapshot(state: "succeeded", eventID: 2)
    }
}
