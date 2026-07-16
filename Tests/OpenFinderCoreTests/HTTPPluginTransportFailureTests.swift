import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginTransportFailureTests: XCTestCase {
    func testRequestFactoryKeepsTokenOnlyInAuthorizationAndRejectsRedirect() throws {
        let endpoint = try HTTPPluginEndpoint("http://127.0.0.1:8765")
        let request = HTTPPluginRequestFactory.make(
            endpoint: endpoint, route: ["jobs"], method: "POST", token: "fixture-token",
            body: Data(#"{"safe":true}"#.utf8)
        )
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8765/openfinder/plugin/v1/jobs")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenFinder-Plugin-Protocol"), "1")
        XCTAssertFalse(request.url!.absoluteString.contains("fixture-token"))
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("fixture-token"))

        let session = URLSessionHTTPPluginTransport.secureSession()
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.urlCache)
        let delegate = HTTPPluginRedirectDelegate()
        let recorder = RedirectRecorder()
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://example.com/steal"])!
        delegate.urlSession(session, task: session.dataTask(with: request), willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://example.com/steal")!)) {
            recorder.record($0)
        }
        XCTAssertTrue(recorder.wasCalled)
        XCTAssertNil(recorder.request)
    }

    func testNegotiationRejectsProtocolPluginAndActionMismatch() async throws {
        let badHeaders = ["openfinder-plugin-protocol": "2", "content-type": "application/json"]
        let wrongPlugin = HTTPPluginResponseFixture.health.replacingOccurrences(
            of: "dev.openfinder.plugins.video-analyzer", with: "dev.example.wrong"
        )
        let missingAction = HTTPPluginResponseFixture.capabilities().replacingOccurrences(
            of: #"{"id":"analyze-video"}"#, with: #"{"id":"other"}"#
        )
        let cases: [@Sendable (URLRequest) -> HTTPPluginDataResponse] = [
            { _ in .init(statusCode: 200, headers: badHeaders, body: Data(HTTPPluginResponseFixture.health.utf8)) },
            { request in request.url!.path.hasSuffix("/health") ? HTTPPluginResponseFixture.data(wrongPlugin) : HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.capabilities()) },
            { request in request.url!.path.hasSuffix("/health") ? HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.health) : HTTPPluginResponseFixture.data(missingAction) }
        ]
        for response in cases {
            let transport = ScriptedHTTPPluginTransport { request, _ in response(request) } stream: { _, _ in
                XCTFail("Negotiation failure must not open SSE")
                return HTTPPluginResponseFixture.stream([])
            }
            await XCTAssertThrowsAsyncError {
                _ = try await self.runner(transport).run(HTTPPluginResponseFixture.request())
            }
            let streamRequests = await transport.capturedStreamRequests()
            XCTAssertTrue(streamRequests.isEmpty)
        }
    }

    func testFailureResultIsNormalResultAndServerErrorRedactsToken() async throws {
        let failureTransport = terminalTransport(result: HTTPPluginResponseFixture.failure)
        let result = try await runner(failureTransport).run(HTTPPluginResponseFixture.request())
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.events.last?.isFailureResult == true)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")

        let eventTokenResult = HTTPPluginResponseFixture.failure.replacingOccurrences(
            of: "model failed", with: "failed fixture-token"
        )
        let redacted = try await runner(terminalTransport(result: eventTokenResult))
            .run(HTTPPluginResponseFixture.request())
        XCTAssertEqual(redacted.events.last?.resultMessage, "failed REDACTED")
        XCTAssertFalse(String(describing: redacted.events).contains("fixture-token"))

        let token = "fixture-token"
        let unauthorized = ScriptedHTTPPluginTransport { _, _ in
            HTTPPluginResponseFixture.data(#"{"schemaVersion":1,"code":"unauthorized","message":"bad fixture-token","retryable":false}"#, status: 401)
        } stream: { _, _ in HTTPPluginResponseFixture.stream([]) }
        do {
            _ = try await runner(unauthorized).run(HTTPPluginResponseFixture.request())
            XCTFail("Expected authentication error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
    }

    private func runner(_ transport: ScriptedHTTPPluginTransport) -> HTTPPluginRunner {
        HTTPPluginRunner(transport: transport, credentialResolver: { _ in "fixture-token" }, sleep: { _ in })
    }

    private func terminalTransport(result: String) -> ScriptedHTTPPluginTransport {
        ScriptedHTTPPluginTransport { request, _ in
            let path = request.url!.path
            if path.hasSuffix("/health") { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.health) }
            if path.hasSuffix("/capabilities") { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.capabilities()) }
            if request.httpMethod == "POST" { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.snapshot(state: "queued", eventID: 0), status: 202) }
            return HTTPPluginResponseFixture.data(result)
        } stream: { _, _ in
            HTTPPluginResponseFixture.stream([HTTPPluginResponseFixture.frame(result, id: 2, type: "result")])
        }
    }
}

private final class RedirectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URLRequest??
    func record(_ request: URLRequest?) { lock.withLock { storage = .some(request) } }
    var wasCalled: Bool { lock.withLock { storage != nil } }
    var request: URLRequest? { lock.withLock { storage ?? nil } }
}

private extension XCTestCase {
    func XCTAssertThrowsAsyncError(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do { try await expression(); XCTFail("Expected error", file: file, line: line) }
        catch { }
    }
}
