import Foundation
import XCTest
@testable import OpenFinderCore

final class WebDAVProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testPropfindListsRemoteDirectoryAndFiltersSelfHref() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
            let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:href>/dav/photos/</D:href>
                <D:propstat><D:prop><D:displayname>photos</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
              </D:response>
              <D:response>
                <D:href>/dav/photos/demo.png</D:href>
                <D:propstat><D:prop><D:displayname>demo.png</D:displayname><D:getcontentlength>42</D:getcontentlength><D:getcontenttype>image/png</D:getcontenttype><D:getlastmodified>Sun, 05 Jul 2026 04:00:00 GMT</D:getlastmodified><D:resourcetype/></D:prop></D:propstat>
              </D:response>
              <D:response>
                <D:href>/dav/photos/folder/</D:href>
                <D:propstat><D:prop><D:displayname>folder</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
              </D:response>
            </D:multistatus>
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 207, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let provider = makeProvider()

        let listing = try await provider.list(directory: RemotePath(identifier: "/photos/", displayPath: "/photos/"))
        let items = listing.items

        XCTAssertEqual(items.map(\.name), ["demo.png", "folder"])
        XCTAssertEqual(items.map(\.remotePath.displayPath), ["/photos/demo.png", "/photos/folder"])
        XCTAssertEqual(items[0].kind, .file)
        XCTAssertEqual(items[0].size, 42)
        XCTAssertEqual(items[0].mimeType, "image/png")
        XCTAssertEqual(items[1].kind, .directory)
    }

    func testListingReturnsParentAndDownloadUsesRemotePathIdentifier() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.append((request.httpMethod ?? "", request.url!.absoluteString, nil, nil))
            if request.httpMethod == "PROPFIND" {
                let body = """
                <?xml version="1.0" encoding="utf-8"?>
                <D:multistatus xmlns:D="DAV:">
                  <D:response>
                    <D:href>/dav/opaque-child-id/</D:href>
                    <D:propstat><D:prop><D:displayname>Opaque Child</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
                  </D:response>
                </D:multistatus>
                """
                return (HTTPURLResponse(url: request.url!, statusCode: 207, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("download".utf8))
        }
        let provider = makeProvider()
        let child = RemotePath(identifier: "/opaque-child-id/", displayPath: "/Personal Space/Opaque Child")
        let expectedParent = RemotePath(identifier: "/", displayPath: "/Personal Space")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinder-WebDAV-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        let listing = try await provider.list(directory: child)
        _ = try await provider.download(item: child, to: destination)

        XCTAssertEqual(listing.parent, expectedParent)
        XCTAssertEqual(recorder.values.map(\.0), ["PROPFIND", "GET"])
        XCTAssertTrue(recorder.values[1].1.hasSuffix("/dav/opaque-child-id"))
    }

    func testSendsWebDAVMutationMethodsWithEncodedDestination() async throws {
        let seen = RequestRecorder()
        MockURLProtocol.handler = { request in
            seen.append((request.httpMethod ?? "", request.url!.absoluteString, request.value(forHTTPHeaderField: "Destination"), request.value(forHTTPHeaderField: "Overwrite")))
            let status = request.httpMethod == "DELETE" ? 204 : 201
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
        }
        let provider = makeProvider()

        let root = RemotePath(identifier: "/", displayPath: "/")
        try await provider.createDirectory(in: root, named: "new folder")
        try await provider.delete(item: RemotePath(identifier: "/old.txt", displayPath: "/old.txt"))
        try await provider.move(item: RemotePath(identifier: "/old name.txt", displayPath: "/old name.txt"), to: root, named: "new name.txt")
        try await provider.copy(item: RemotePath(identifier: "/source.txt", displayPath: "/source.txt"), to: root, named: "copy.txt")

        let requests = seen.values
        XCTAssertEqual(requests.map(\.0), ["MKCOL", "DELETE", "MOVE", "COPY"])
        XCTAssertTrue(requests[0].1.hasSuffix("/dav/new%20folder"))
        XCTAssertEqual(requests[2].2, "https://example.test/dav/new%20name.txt")
        XCTAssertEqual(requests[2].3, "F")
        XCTAssertEqual(requests[3].2, "https://example.test/dav/copy.txt")
        XCTAssertEqual(requests[3].3, "F")
    }


    func testCredentialedWebDAVRequiresHTTPSAndExistingSecret() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let missingSecretAccount = RemoteAccount(id: UUID(), name: "Missing", provider: .webDAV, baseURL: URL(string: "https://example.test/dav/")!, username: "me", secretKeychainRef: "missing", options: [:])
        let missingProvider = WebDAVProvider(account: missingSecretAccount, credentialStore: InMemoryKeychainStore(), session: session)

        do {
            _ = try await missingProvider.list(directory: RemotePath(identifier: "/", displayPath: "/"))
            XCTFail("Expected missing secret failure")
        } catch OpenFinderError.missingSecret("missing") {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let keychain = InMemoryKeychainStore()
        try keychain.setSecret("pw", for: "secret")
        let httpAccount = RemoteAccount(id: UUID(), name: "HTTP", provider: .webDAV, baseURL: URL(string: "http://example.test/dav/")!, username: "me", secretKeychainRef: "secret", options: [:])
        let httpProvider = WebDAVProvider(account: httpAccount, credentialStore: keychain, session: session)
        do {
            _ = try await httpProvider.list(directory: RemotePath(identifier: "/", displayPath: "/"))
            XCTFail("Expected insecure transport failure")
        } catch OpenFinderError.operationFailed(let message) {
            XCTAssertTrue(message.contains("HTTPS"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWebDAVMultiStatusFailureIsNotTreatedAsSuccess() async throws {
        MockURLProtocol.handler = { request in
            let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:href>/dav/locked.txt</D:href>
                <D:status>HTTP/1.1 423 Locked</D:status>
              </D:response>
            </D:multistatus>
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 207, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let provider = makeProvider()

        do {
            try await provider.delete(item: RemotePath(identifier: "/locked.txt", displayPath: "/locked.txt"))
            XCTFail("Expected 207 child failure")
        } catch OpenFinderError.webDAVUnexpectedStatus(423, "DELETE") {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }


    func testPropfindToleratesPropertyLevelNotFoundAndAbsoluteHrefs() async throws {
        MockURLProtocol.handler = { request in
            let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:href>https://example.test/dav/photos/absolute.png</D:href>
                <D:propstat>
                  <D:prop><D:displayname>absolute.png</D:displayname><D:getcontentlength>7</D:getcontentlength><D:resourcetype/></D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
                <D:propstat>
                  <D:prop><D:getetag/></D:prop>
                  <D:status>HTTP/1.1 404 Not Found</D:status>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 207, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let provider = makeProvider()

        let items = try await provider.list(directory: RemotePath(identifier: "/photos/", displayPath: "/photos/")).items

        XCTAssertEqual(items.map(\.remotePath.displayPath), ["/photos/absolute.png"])
        XCTAssertEqual(items.first?.size, 7)
    }

    func testUploadUsesCreateOnlyPreconditionAndDownloadRefusesExistingLocalFile() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.append((request.httpMethod ?? "", request.url!.absoluteString, request.value(forHTTPHeaderField: "If-None-Match"), nil))
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }
        let provider = makeProvider()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderWebDAVConflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let upload = root.appendingPathComponent("upload.txt")
        try "upload".write(to: upload, atomically: true, encoding: .utf8)

        _ = try await provider.upload(localURL: upload, to: RemotePath(identifier: "/", displayPath: "/"), named: "upload.txt")
        XCTAssertEqual(recorder.values.first?.2, "*")

        let existingDownload = root.appendingPathComponent("download.txt")
        try "existing".write(to: existingDownload, atomically: true, encoding: .utf8)
        do {
            _ = try await provider.download(item: RemotePath(identifier: "/download.txt", displayPath: "/download.txt"), to: existingDownload)
            XCTFail("Expected local destination conflict")
        } catch OpenFinderError.operationFailed(let message) {
            XCTAssertTrue(message.contains("already exists"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }


    func testUploadRejectsOverwriteStyleSuccessWhenUsingCreateOnlyPrecondition() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let provider = makeProvider()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderWebDAVUnsafeUpload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let upload = root.appendingPathComponent("upload.txt")
        try "upload".write(to: upload, atomically: true, encoding: .utf8)

        do {
            _ = try await provider.upload(localURL: upload, to: RemotePath(identifier: "/", displayPath: "/"), named: "upload.txt")
            XCTFail("Expected unsafe overwrite-style status to fail")
        } catch OpenFinderError.webDAVUnexpectedStatus(200, "PUT") {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeProvider() -> WebDAVProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let account = RemoteAccount(id: UUID(), name: "Test", provider: .webDAV, baseURL: URL(string: "https://example.test/dav/")!, username: "me", secretKeychainRef: "secret", options: [:])
        let keychain = InMemoryKeychainStore()
        try! keychain.setSecret("pw", for: "secret")
        return WebDAVProvider(account: account, credentialStore: keychain, session: session)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: OpenFinderError.operationFailed("No handler"))
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


private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, String, String?, String?)] = []

    var values: [(String, String, String?, String?)] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ value: (String, String, String?, String?)) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }
}
