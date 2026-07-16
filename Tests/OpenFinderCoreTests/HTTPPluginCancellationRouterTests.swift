import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginCancellationRouterTests: XCTestCase {
    func testExternalAndTaskCancellationShareExactlyOneDelete() async throws {
        let control = ControlledHTTPPluginStream()
        let transport = Self.cancellationTransport(control: control)
        let runner = HTTPPluginRunner(
            transport: transport, credentialResolver: { _ in "fixture-token" },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )
        let runTask = Task { try await runner.run(HTTPPluginResponseFixture.request()) }
        try await waitForStream(transport)

        async let external: Void = runner.cancel(taskID: HTTPPluginTestFixture.taskID)
        runTask.cancel()
        _ = await external

        do {
            _ = try await runTask.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let deletes = await transport.capturedDataRequests().filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(deletes[0].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
    }

    func testCancellationAckTimeoutStillThrowsCancellationAndSendsOneDelete() async throws {
        let control = ControlledHTTPPluginStream()
        let transport = Self.cancellationTransport(control: control, hangDelete: true)
        let runner = HTTPPluginRunner(
            transport: transport, credentialResolver: { _ in "fixture-token" }, sleep: { _ in }
        )
        let task = Task { try await runner.run(HTTPPluginResponseFixture.request()) }
        try await waitForStream(transport)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let deletes = await transport.capturedDataRequests().filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.count, 1)
    }

    func testRouterCancelsOnlyMappedTransport() async throws {
        let process = RunnerProbe()
        let http = RunnerProbe()
        let router = PluginRunnerRouter(processRunner: process, httpRunner: http)
        let httpRequest = HTTPPluginResponseFixture.request()
        let httpTask = Task { try await router.run(httpRequest) }
        try await waitUntilStarted(http)

        await router.cancel(taskID: httpRequest.input.taskID)
        _ = try await httpTask.value

        let httpCountAfterHTTP = await http.cancelCount()
        let processCountAfterHTTP = await process.cancelCount()
        XCTAssertEqual(httpCountAfterHTTP, 1)
        XCTAssertEqual(processCountAfterHTTP, 0)

        let processRequest = Self.processRequest()
        let processTask = Task { try await router.run(processRequest) }
        try await waitUntilStarted(process)
        await router.cancel(taskID: processRequest.input.taskID)
        _ = try await processTask.value

        let processCount = await process.cancelCount()
        let httpCount = await http.cancelCount()
        XCTAssertEqual(processCount, 1)
        XCTAssertEqual(httpCount, 1)
    }

    private static func cancellationTransport(
        control: ControlledHTTPPluginStream, hangDelete: Bool = false
    ) -> ScriptedHTTPPluginTransport {
        ScriptedHTTPPluginTransport { request, _ in
            guard let path = request.url?.path else { throw URLError(.badURL) }
            if path.hasSuffix("/health") { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.health) }
            if path.hasSuffix("/capabilities") { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.capabilities()) }
            if request.httpMethod == "POST" { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.snapshot(state: "queued", eventID: 0), status: 202) }
            if request.httpMethod == "DELETE" {
                if hangDelete { try await Task.sleep(for: .seconds(60)) }
                control.finishCancelled()
                return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.snapshot(state: "cancelling", eventID: 0), status: 202)
            }
            if path.hasSuffix("/result") { return HTTPPluginResponseFixture.data(ControlledHTTPPluginStream.cancelledResult) }
            throw URLError(.badServerResponse)
        } stream: { _, _ in
            control.response
        }
    }

    private func waitForStream(_ transport: ScriptedHTTPPluginTransport) async throws {
        for _ in 0 ..< 1_000 {
            if await !transport.capturedStreamRequests().isEmpty { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw HTTPPluginError.transport("test stream did not start")
    }

    private func waitUntilStarted(_ probe: RunnerProbe) async throws {
        for _ in 0 ..< 1_000 {
            if await probe.hasStarted() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw HTTPPluginError.transport("test runner did not start")
    }

    private static func processRequest() -> PluginRunRequest {
        let manifest = HTTPPluginTestFixture.manifest(execution: .process(runtime: .shell, entry: "run.sh"))
        let input = HTTPPluginTestFixture.input()
        return .init(manifest: manifest, action: manifest.actions[0], input: input, environment: [:],
                     pluginDirectory: URL(fileURLWithPath: "/tmp"), workingDirectory: URL(fileURLWithPath: "/tmp"))
    }
}

private final class ControlledHTTPPluginStream: @unchecked Sendable {
    static let cancelledResult = #"{"schemaVersion":1,"eventID":1,"taskID":"11111111-1111-1111-1111-111111111111","type":"result","status":"cancelled","artifacts":[]}"#
    let response: HTTPPluginStreamResponse
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        let chunks = AsyncThrowingStream<Data, Error> { captured = $0 }
        continuation = captured
        response = .init(statusCode: 200, headers: HTTPPluginResponseFixture.streamHeaders, chunks: chunks)
    }

    func finishCancelled() {
        continuation.yield(Data(HTTPPluginResponseFixture.frame(Self.cancelledResult, id: 1, type: "result").utf8))
        continuation.finish()
    }
}

private actor RunnerProbe: PluginRunner {
    private var started = false
    private var cancelled = false
    private var cancellations = 0

    func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        _ = request
        started = true
        while !cancelled { try await Task.sleep(for: .milliseconds(1)) }
        return .init(exitCode: 0, events: [], stdout: "", stderr: "")
    }

    func cancel(taskID: UUID) {
        _ = taskID
        cancellations += 1
        cancelled = true
    }

    func hasStarted() -> Bool { started }
    func cancelCount() -> Int { cancellations }
}
