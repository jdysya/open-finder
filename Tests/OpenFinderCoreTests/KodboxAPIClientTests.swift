import Foundation
import XCTest
@testable import OpenFinderCore

final class KodboxAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KodboxURLProtocol.reset()
    }

    override func tearDown() {
        KodboxURLProtocol.reset()
        super.tearDown()
    }

    func testBootstrapUsesNativeLoginRouteAndPostsCredentialsOnlyInBody() async throws {
        let recorder = KodboxRequestRecorder()
        KodboxURLProtocol.handler = { request in
            recorder.append(request)
            switch recorder.values.count {
            case 1:
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case 2:
                return Self.response(for: request, body: #"{"code":1,"data":{"version":"1.68.10"}}"#)
            default:
                throw KodboxFixtureError.unexpectedRequest
            }
        }

        let session = KodboxAPISession(
            baseURL: URL(string: "https://kodbox.test/")!,
            credentials: .init(username: "alice+ops", password: "pass&word = 123"),
            session: makeURLSession()
        )

        let bootstrap = try await session.bootstrap()

        XCTAssertEqual(bootstrap.version, "1.68.10")
        let requests = recorder.values
        XCTAssertEqual(requests.count, 2)
        let login = try XCTUnwrap(requests.first)
        XCTAssertEqual(login.httpMethod, "POST")
        XCTAssertEqual(login.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=utf-8")
        XCTAssertEqual(login.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
        XCTAssertFalse(login.url?.absoluteString.contains("pass") == true)
        XCTAssertFalse(login.url?.absoluteString.contains("alice") == true)
        XCTAssertEqual(login.url?.path, "/index.php")
        XCTAssertEqual(login.url?.query, "user/index/loginSubmit")
        XCTAssertNil(login.url?.queryValue(named: "app"))
        XCTAssertEqual(login.bodyFormValues?["name"], "alice+ops")
        XCTAssertEqual(login.bodyFormValues?["password"], "pass&word = 123")
        XCTAssertNil(login.bodyFormValues?["user"])
        XCTAssertNil(login.bodyFormValues?["pwd"])

        let options = try XCTUnwrap(requests.last)
        XCTAssertEqual(options.url?.path, "/index.php")
        XCTAssertEqual(options.url?.kodboxRoute, "user/view/options")
        XCTAssertNil(options.url?.queryValue(named: "app"))
        XCTAssertEqual(options.url?.queryValue(named: "accessToken"), "fixture-access-token")
    }

    func testDiagnosticsRedactAccessTokenAndPassword() async throws {
        let password = "not-for-logs"
        let token = "not-for-logs-token"
        KodboxURLProtocol.handler = { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"not-for-logs-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, status: 502, body: "gateway failure")
            default:
                throw KodboxFixtureError.unexpectedRequest
            }
        }
        let session = KodboxAPISession(
            baseURL: URL(string: "https://kodbox.test/")!,
            credentials: .init(username: "alice", password: password),
            session: makeURLSession()
        )

        do {
            _ = try await session.bootstrap()
            XCTFail("Expected a redacted transport failure")
        } catch {
            let diagnostic = String(describing: error)
            XCTAssertFalse(diagnostic.contains(password))
            XCTAssertFalse(diagnostic.contains(token))
            XCTAssertTrue(diagnostic.contains("accessToken=REDACTED"))
        }
    }

    func testBootstrapAcceptsKodbox168Version() async throws {
        KodboxURLProtocol.handler = Self.successfulBootstrap(version: "1.68.9")
        let session = makeSession()

        let bootstrap = try await session.bootstrap()
        XCTAssertEqual(bootstrap.version, "1.68.9")
    }

    func testBootstrapAcceptsVersionNestedInNativeOptionsPayload() async throws {
        KodboxURLProtocol.handler = { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":"ok","info":"fixture-access-token"}"#)
            case "user/view/options":
                return Self.response(for: request, body: #"{"code":true,"data":{"kod":{"version":"1.68"}}}"#)
            default:
                throw KodboxFixtureError.unexpectedRequest
            }
        }

        let bootstrap = try await makeSession().bootstrap()

        XCTAssertEqual(bootstrap.version, "1.68")
    }

    func testBootstrapAcceptsNativeLoginTokenInInfo() async throws {
        KodboxURLProtocol.handler = { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":"ok","info":"fixture-access-token"}"#)
            case "user/view/options":
                XCTAssertEqual(request.url?.queryValue(named: "accessToken"), "fixture-access-token")
                return Self.response(for: request, body: #"{"code":true,"data":{"version":"1.68.10"}}"#)
            default:
                throw KodboxFixtureError.unexpectedRequest
            }
        }

        let bootstrap = try await makeSession().bootstrap()

        XCTAssertEqual(bootstrap.version, "1.68.10")
    }

    func testBootstrapRejectsUnsupportedVersion() async throws {
        KodboxURLProtocol.handler = Self.successfulBootstrap(version: "1.69.0")
        let session = makeSession()

        await XCTAssertThrowsErrorAsync(try await session.bootstrap()) { error in
            guard case KodboxAPIError.incompatibleServer(let version) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(version, "1.69.0")
        }
    }

    func testLoginFailsClosedForMalformedEnvelope() async throws {
        KodboxURLProtocol.handler = { request in
            Self.response(for: request, body: #"{"code":true,"accessToken":"wrong-shape"}"#)
        }

        await XCTAssertThrowsErrorAsync(try await makeSession().bootstrap()) { error in
            XCTAssertEqual(error as? KodboxAPIError, .malformedResponse(endpoint: .login))
        }
    }

    func testLoginMapsCaptchaRequirement() async throws {
        KodboxURLProtocol.handler = { request in
            Self.response(for: request, body: #"{"code":false,"data":{"captcha":true},"message":"Verification required"}"#)
        }

        await XCTAssertThrowsErrorAsync(try await makeSession().bootstrap()) { error in
            XCTAssertEqual(error as? KodboxAPIError, .captchaRequired)
        }
    }

    func testLoginMapsAuthenticationFailure() async throws {
        KodboxURLProtocol.handler = { request in
            Self.response(for: request, body: #"{"code":0,"message":"invalid credentials","data":null}"#)
        }

        await XCTAssertThrowsErrorAsync(try await makeSession().bootstrap()) { error in
            XCTAssertEqual(error as? KodboxAPIError, .authenticationFailed)
        }
    }

    func testLocalizedAPIErrorPreservesMessageWithoutTreatingItAsAuthenticationFailure() async throws {
        KodboxURLProtocol.handler = { request in
            Self.response(for: request, body: #"{"code":false,"message":"没有权限","data":null}"#)
        }

        await XCTAssertThrowsErrorAsync(try await makeSession().bootstrap()) { error in
            XCTAssertEqual(error as? KodboxAPIError, .apiRejected(message: "没有权限"))
        }
    }

    func testSessionSharesOneConcurrentLogin() async throws {
        let recorder = KodboxRequestRecorder()
        KodboxURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.kodboxRoute == "user/index/loginSubmit" {
                Thread.sleep(forTimeInterval: 0.05)
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            }
            return Self.response(for: request, body: #"{"code":true,"data":{"version":"1.68.10"}}"#)
        }
        let session = makeSession()

        async let first = session.bootstrap()
        async let second = session.bootstrap()
        _ = try await (first, second)

        XCTAssertEqual(recorder.values.filter { $0.url?.kodboxRoute == "user/index/loginSubmit" }.count, 1)
    }

    func testCancelledBootstrapWaiterDoesNotCancelSharedLogin() async throws {
        let gate = KodboxLoginGate()
        let recorder = KodboxRequestRecorder()
        KodboxURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.kodboxRoute == "user/index/loginSubmit" {
                gate.loginStarted.signal()
                _ = gate.allowLogin.wait(timeout: .now() + 2)
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            }
            return Self.response(for: request, body: #"{"code":true,"data":{"version":"1.68.10"}}"#)
        }
        let session = makeSession()
        let cancelledWaiter = Task { try await session.bootstrap() }
        XCTAssertEqual(gate.loginStarted.wait(timeout: .now() + 2), .success)
        let survivingWaiter = Task { try await session.bootstrap() }

        cancelledWaiter.cancel()
        gate.allowLogin.signal()

        let survivingBootstrap = try await survivingWaiter.value
        XCTAssertEqual(survivingBootstrap.version, "1.68.10")
        _ = try? await cancelledWaiter.value
        XCTAssertEqual(recorder.values.filter { $0.url?.kodboxRoute == "user/index/loginSubmit" }.count, 1)
    }

    func testAuthenticatedRequestReloginsAndRetriesExactlyOnce() async throws {
        let recorder = KodboxRequestRecorder()
        KodboxURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                let number = recorder.values.filter { $0.url?.kodboxRoute == "user/index/loginSubmit" }.count
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"token-\#(number)"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: #"{"code":true,"data":{"version":"1.68.10"}}"#)
            case "explorer/list/path":
                let token = request.url?.queryValue(named: "accessToken")
                if token == "token-1" {
                    return Self.response(for: request, body: #"{"code":0,"message":"login expired","data":null}"#)
                }
                return Self.response(for: request, body: #"{"code":true,"data":{"name":"ok"}}"#)
            default:
                throw KodboxFixtureError.unexpectedRequest
            }
        }
        let session = makeSession()

        let response: KodboxFixturePayload = try await session.perform(.explorerList, form: ["path": "{source:5}/"], response: KodboxFixturePayload.self)

        XCTAssertEqual(response.name, "ok")
        XCTAssertEqual(recorder.values.filter { $0.url?.kodboxRoute == "user/index/loginSubmit" }.count, 2)
        XCTAssertEqual(recorder.values.filter { $0.url?.kodboxRoute == "explorer/list/path" }.count, 2)
    }

    func testAuthenticatedRequestFailsAfterOneRetry() async throws {
        let recorder = KodboxRequestRecorder()
        KodboxURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: #"{"code":true,"data":{"version":"1.68.10"}}"#)
            case "explorer/list/path":
                return Self.response(for: request, body: #"{"code":false,"message":"login expired","data":null}"#)
            default:
                throw KodboxFixtureError.unexpectedRequest
            }
        }
        let session = makeSession()

        await XCTAssertThrowsErrorAsync(try await session.perform(.explorerList, form: ["path": "{source:5}/"], response: KodboxFixturePayload.self)) { error in
            XCTAssertEqual(error as? KodboxAPIError, .authenticationFailed)
        }
        XCTAssertEqual(recorder.values.filter { $0.url?.kodboxRoute == "user/index/loginSubmit" }.count, 2)
        XCTAssertEqual(recorder.values.filter { $0.url?.kodboxRoute == "explorer/list/path" }.count, 2)
    }

    private func makeSession() -> KodboxAPISession {
        KodboxAPISession(
            baseURL: URL(string: "https://kodbox.test/")!,
            credentials: .init(username: "alice", password: "pass&word = 123"),
            session: makeURLSession()
        )
    }

    private func makeURLSession() -> URLSession {
        KodboxHTTPClient.ephemeralSession(protocolClasses: [KodboxURLProtocol.self])
    }

    private static func successfulBootstrap(version: String) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return response(for: request, body: #"{"code":true,"data":{"version":"\#(version)"}}"#)
            default:
                throw KodboxFixtureError.unexpectedRequest
            }
        }
    }

    private static func response(for request: URLRequest, status: Int = 200, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
    }
}

private struct KodboxFixturePayload: Decodable, Equatable, Sendable {
    let name: String
}

private enum KodboxFixtureError: Error {
    case unexpectedRequest
}

private final class KodboxURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: KodboxFixtureError.unexpectedRequest)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class KodboxRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var values: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        storage.append(request)
    }
}

private final class KodboxLoginGate: @unchecked Sendable {
    let loginStarted = DispatchSemaphore(value: 0)
    let allowLogin = DispatchSemaphore(value: 0)
}

private extension URL {
    var kodboxRoute: String? {
        query?
            .split(separator: "&", maxSplits: 1)
            .first
            .map(String.init)
    }

    func queryValue(named name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value
    }
}

private extension URLRequest {
    var bodyFormValues: [String: String]? {
        let data: Data
        if let httpBody {
            data = httpBody
        } else if let httpBodyStream {
            httpBodyStream.open()
            defer { httpBodyStream.close() }

            var buffer = [UInt8](repeating: 0, count: 1_024)
            var body = Data()
            while true {
                let bytesRead = httpBodyStream.read(&buffer, maxLength: buffer.count)
                guard bytesRead >= 0 else { return nil }
                guard bytesRead > 0 else { break }
                body.append(buffer, count: bytesRead)
            }
            data = body
        } else {
            return nil
        }

        guard let body = String(data: data, encoding: .utf8) else { return nil }
        return URLComponents(string: "?\(body)")?.queryItems?.reduce(into: [:]) { result, item in
            result[item.name] = item.value
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
