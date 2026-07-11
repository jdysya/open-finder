import Foundation
import XCTest
@testable import OpenFinderCore

final class RemoteProviderRegistryTests: XCTestCase {
    func testConfiguredFactoryBuildsWebDAVProvider() async throws {
        let accountID = "webdav-account"
        let account = RemoteAccount(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Files",
            provider: .webDAV,
            baseURL: URL(string: "https://files.example.test/dav/")!,
            username: "admin",
            secretKeychainRef: "remote.webdav.password",
            options: ["connectorID": RemoteConnectorID.webDAV.rawValue]
        )
        let keychain = InMemoryKeychainStore()
        try keychain.setSecret("webdav-password", for: "remote.webdav.password")
        let registry = RemoteProviderRegistry(
            connectorRegistry: .builtIn,
            account: { requestedID in requestedID == accountID ? account : nil },
            credentialStore: keychain
        )

        let provider = try await registry.resolve(accountID: accountID, revision: "r1")

        let webDAVProvider = try XCTUnwrap(provider as? WebDAVProvider)
        let resolvedAccount = await webDAVProvider.account
        XCTAssertEqual(resolvedAccount, account)
    }

    func testConfiguredFactoryBuildsKodboxProviderWithAccountCredentialsAndSession() async throws {
        let accountID = "kodbox-account"
        let account = RemoteAccount(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Team Kodbox",
            provider: .kodbox,
            baseURL: URL(string: "https://box.example.test/")!,
            username: "admin",
            secretKeychainRef: "remote.kodbox.password",
            options: ["connectorID": RemoteConnectorID.kodbox.rawValue]
        )
        let keychain = InMemoryKeychainStore()
        try keychain.setSecret("kodbox-password", for: "remote.kodbox.password")
        let recorder = KodboxFactoryRequestRecorder()
        let session = makeKodboxFactorySession(recorder: recorder)
        let registry = RemoteProviderRegistry(
            connectorRegistry: .builtIn,
            account: { requestedID in requestedID == accountID ? account : nil },
            credentialStore: keychain,
            kodboxSession: { session }
        )

        let provider = try await registry.resolve(accountID: accountID, revision: "r1")

        XCTAssertTrue(provider is KodboxProvider)
        _ = try await provider.list(directory: .init(
            identifier: KodboxProvider.syntheticRootIdentifier,
            displayPath: "/"
        ))
        let requests = recorder.requests()
        XCTAssertEqual(requests.map(\.url?.path), ["/index.php", "/index.php", "/index.php"])
        XCTAssertEqual(requests[0].url?.kodboxRoute, "user/index/loginSubmit")
        XCTAssertEqual(requests[0].bodyFormValues, ["name": "admin", "password": "kodbox-password"])
    }

    func testConfiguredFactoryRejectsUnknownConnector() async throws {
        let account = RemoteAccount(
            name: "Unknown",
            provider: .s3,
            baseURL: URL(string: "https://storage.example.test/")!,
            username: nil,
            secretKeychainRef: nil,
            options: ["connectorID": "s3"]
        )
        let registry = RemoteProviderRegistry(
            connectorRegistry: .builtIn,
            account: { _ in account },
            credentialStore: InMemoryKeychainStore()
        )

        do {
            _ = try await registry.resolve(accountID: "unknown-account", revision: "r1")
            XCTFail("Expected an unsupported-provider error")
        } catch let error as RemoteProviderRegistry.UnsupportedProviderError {
            XCTAssertEqual(error, .init(accountID: "unknown-account", revision: "r1"))
        }
    }

    func testResolveReusesProviderForSameAccountAndRevision() async throws {
        let factory = ProviderFactory()
        let registry = RemoteProviderRegistry(factory: { accountID, revision in
            await factory.make(accountID: accountID, revision: revision)
        })

        let first = try await registry.resolve(accountID: "account-1", revision: "r1")
        let second = try await registry.resolve(accountID: "account-1", revision: "r1")

        XCTAssertTrue((first as AnyObject) === (second as AnyObject))
        let count = await factory.callCount()
        XCTAssertEqual(count, 1)
    }

    func testResolveCreatesNewProviderForDifferentRevision() async throws {
        let factory = ProviderFactory()
        let registry = RemoteProviderRegistry(factory: { accountID, revision in
            await factory.make(accountID: accountID, revision: revision)
        })

        let first = try await registry.resolve(accountID: "account-1", revision: "r1")
        let second = try await registry.resolve(accountID: "account-1", revision: "r2")

        XCTAssertFalse((first as AnyObject) === (second as AnyObject))
        let count = await factory.callCount()
        XCTAssertEqual(count, 2)
    }

    func testResolveCreatesNewProviderForDifferentAccount() async throws {
        let factory = ProviderFactory()
        let registry = RemoteProviderRegistry(factory: { accountID, revision in
            await factory.make(accountID: accountID, revision: revision)
        })

        let first = try await registry.resolve(accountID: "account-1", revision: "r1")
        let second = try await registry.resolve(accountID: "account-2", revision: "r1")

        XCTAssertFalse((first as AnyObject) === (second as AnyObject))
        let count = await factory.callCount()
        XCTAssertEqual(count, 2)
    }

    func testInvalidateEvictsProviderForAccountAndRevision() async throws {
        let factory = ProviderFactory()
        let registry = RemoteProviderRegistry(factory: { accountID, revision in
            await factory.make(accountID: accountID, revision: revision)
        })

        let first = try await registry.resolve(accountID: "account-1", revision: "r1")
        await registry.invalidate(accountID: "account-1", revision: "r1")
        let second = try await registry.resolve(accountID: "account-1", revision: "r1")

        XCTAssertFalse((first as AnyObject) === (second as AnyObject))
        let count = await factory.callCount()
        XCTAssertEqual(count, 2)
    }

    func testResolvePropagatesTypedUnsupportedProviderError() async {
        let registry = RemoteProviderRegistry { accountID, revision in
            throw RemoteProviderRegistry.UnsupportedProviderError(
                accountID: accountID,
                revision: revision
            )
        }

        do {
            _ = try await registry.resolve(accountID: "account-1", revision: "r1")
            XCTFail("Expected resolve to throw an unsupported-provider error")
        } catch let error as RemoteProviderRegistry.UnsupportedProviderError {
            XCTAssertEqual(error, .init(accountID: "account-1", revision: "r1"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor ProviderFactory {
    private(set) var count = 0

    func make(accountID: String, revision: String) -> any RemoteProvider {
        count += 1
        return FakeRemoteProvider(accountID: accountID, revision: revision)
    }

    func callCount() -> Int {
        count
    }
}

private actor FakeRemoteProvider: RemoteProvider {
    let accountID: String
    let revision: String

    init(accountID: String, revision: String) {
        self.accountID = accountID
        self.revision = revision
    }

    func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        throw FakeProviderError.unimplemented
    }

    func createDirectory(in parent: RemotePath, named name: String) async throws {
        throw FakeProviderError.unimplemented
    }

    func delete(item: RemotePath) async throws {
        throw FakeProviderError.unimplemented
    }

    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {
        throw FakeProviderError.unimplemented
    }

    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {
        throw FakeProviderError.unimplemented
    }

    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID {
        throw FakeProviderError.unimplemented
    }

    func download(item: RemotePath, to localURL: URL) async throws -> TaskID {
        throw FakeProviderError.unimplemented
    }
}

private enum FakeProviderError: Error {
    case unimplemented
}

private final class KodboxFactoryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}

private func makeKodboxFactorySession(recorder: KodboxFactoryRequestRecorder) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [KodboxFactoryURLProtocol.self]
    KodboxFactoryURLProtocol.handler = { request in
        recorder.record(request)
        let response: String
        switch request.url?.kodboxRoute {
        case "user/index/loginSubmit":
            response = #"{"code":true,"data":{"accessToken":"test-token"}}"#
        case "user/view/options":
            response = #"{"code":true,"data":{"version":"1.68.10","user":{"myhome":"{source:1}/"}}}"#
        default:
            throw URLError(.badServerResponse)
        }
        return (
            HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(response.utf8)
        )
    }
    return URLSession(configuration: configuration)
}

private final class KodboxFactoryURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request) ?? { throw URLError(.badServerResponse) }()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URL {
    var kodboxRoute: String? {
        query?
            .split(separator: "&", maxSplits: 1)
            .first
            .map(String.init)
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
