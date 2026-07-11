import Foundation
import XCTest
@testable import OpenFinderCore

final class KodboxProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KodboxProviderURLProtocol.reset()
    }

    override func tearDown() {
        KodboxProviderURLProtocol.reset()
        super.tearDown()
    }

    func testListSyntheticRootReturnsSafeNavigationEntriesWithoutExplorerRequest() async throws {
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())

        let listing = try await provider.list(directory: .init(identifier: "kodbox:user-space-root", displayPath: "/"))

        XCTAssertEqual(listing.current.identifier, "kodbox:user-space-root")
        XCTAssertNil(listing.parent)
        XCTAssertEqual(listing.items.map(\.name), ["Personal", "Desktop", "Team Space", "Shared with Me", "My Shares", "Favorites"])
        XCTAssertEqual(listing.items.map(\.remotePath.identifier), ["{source:5}/", "{source:6}/", "{groupRootSelf}", "{shareToMe}", "{userShare}", "{userFav}"])
        XCTAssertTrue(listing.items.allSatisfy(\.isReadable))
        XCTAssertTrue(listing.items.allSatisfy { !$0.isWritable })
        XCTAssertTrue(recorder.values.allSatisfy { $0.url?.kodboxRoute != "explorer/list/path" })
    }

    func testListRealVirtualRootSendsItsOpaquePathAndNeverServerRoot() async throws {
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/list/path":
                return Self.response(for: request, body: #"{"code":true,"data":{"folderList":[],"fileList":[]}}"#)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())

        _ = try await provider.list(directory: .init(identifier: "{source:5}/", displayPath: "/Personal"))

        let explorerPaths = recorder.values
            .filter { $0.url?.kodboxRoute == "explorer/list/path" }
            .compactMap(\.bodyFormValues?["path"])
        XCTAssertEqual(explorerPaths, ["{source:5}/"])
        XCTAssertFalse(explorerPaths.contains("/"))
    }

    func testListRealVirtualRootReturnsNativeFolderAndFileItems() async throws {
        KodboxProviderURLProtocol.handler = { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/list/path":
                return Self.response(for: request, body: #"{"code":true,"data":{"folderList":[{"name":"Projects","path":"{source:5}/Projects/","size":null,"modifyTime":null,"isFolder":null}],"fileList":[{"name":"notes.txt","path":"{source:5}/notes.txt","size":42,"modifyTime":1700000010,"isFolder":0}]}}"#)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())

        let listing = try await provider.list(directory: .init(identifier: "{source:5}/", displayPath: "/Personal"))

        XCTAssertEqual(listing.items.map(\.name), ["Projects", "notes.txt"])
        XCTAssertEqual(listing.items.map(\.kind), [.directory, .file])
        XCTAssertEqual(listing.items.map(\.remotePath.identifier), ["{source:5}/Projects/", "{source:5}/notes.txt"])
        XCTAssertEqual(listing.items.map(\.size), [nil, 42])
        XCTAssertEqual(listing.items.map(\.modificationDate), [nil, Date(timeIntervalSince1970: 1_700_000_010)])
    }

    func testMutationsUseNativeRoutesWithOpaqueIdentifiersAndNeverServerRoot() async throws {
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/index/mkdir", "explorer/index/mkfile", "explorer/index/pathRename", "explorer/index/pathDelete", "explorer/index/pathCopyTo", "explorer/index/pathCuteTo":
                return Self.response(for: request, body: #"{"code":true,"data":{}}"#)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())
        let parent = RemotePath(identifier: "{source:5}/projects/", displayPath: "/Personal/projects")
        let source = RemotePath(identifier: "{source:5}/projects/original.txt", displayPath: "/Personal/projects/original.txt")
        let destination = RemotePath(identifier: "{source:6}/archive/", displayPath: "/Desktop/archive")

        try await provider.createDirectory(in: parent, named: "new folder")
        try await provider.createFile(in: parent, named: "draft.txt")
        try await provider.rename(item: source, named: "renamed.txt")
        try await provider.delete(item: source)
        try await provider.copy(item: source, to: destination, named: "copied.txt")
        try await provider.move(item: source, to: destination, named: "moved.txt")

        let mutations = recorder.values.filter { request in
            switch request.url?.kodboxRoute {
            case "explorer/index/mkdir", "explorer/index/mkfile", "explorer/index/pathRename", "explorer/index/pathDelete", "explorer/index/pathCopyTo", "explorer/index/pathCuteTo":
                true
            default:
                false
            }
        }
        XCTAssertEqual(mutations.map { $0.url?.kodboxRoute }, [
            "explorer/index/mkdir",
            "explorer/index/mkfile",
            "explorer/index/pathRename",
            "explorer/index/pathDelete",
            "explorer/index/pathCopyTo",
            "explorer/index/pathCuteTo"
        ])
        XCTAssertEqual(mutations.map(\.bodyFormValues), [
            ["path": "{source:5}/projects/new folder"],
            ["path": "{source:5}/projects/draft.txt"],
            ["path": "{source:5}/projects/original.txt", "newName": "renamed.txt"],
            ["dataArr": #"[{"path":"{source:5}/projects/original.txt"}]"#],
            ["dataArr": #"[{"path":"{source:5}/projects/original.txt","name":"copied.txt"}]"#, "path": "{source:6}/archive/"],
            ["dataArr": #"[{"path":"{source:5}/projects/original.txt","name":"moved.txt"}]"#, "path": "{source:6}/archive/"]
        ])
        XCTAssertFalse(mutations.contains { $0.bodyFormValues?.values.contains("/") == true })
    }

    func testMutationsRejectNavigationRootAndServerRootWithoutRequest() async throws {
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            throw KodboxProviderFixtureError.unexpectedRequest
        }
        let provider = KodboxProvider(session: makeSession())

        do {
            try await provider.createDirectory(
                in: .init(identifier: KodboxProvider.syntheticRootIdentifier, displayPath: "/"),
                named: "blocked"
            )
            XCTFail("Expected the navigation root to reject mutations")
        } catch {}
        do {
            try await provider.createFile(
                in: .init(identifier: "/", displayPath: "/"),
                named: "blocked.txt"
            )
            XCTFail("Expected the Kodbox server root to reject mutations")
        } catch {}

        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testUploadPostsMultipartFileToOpaqueParentAndNeverServerRoot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localFile = root.appendingPathComponent("local.txt")
        try Data("file contents".utf8).write(to: localFile)
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/upload/fileUpload":
                return Self.response(for: request, body: #"{"code":true,"data":{}}"#)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())
        let parent = RemotePath(identifier: "{source:5}/projects/", displayPath: "/Personal/projects")

        let taskID = try await provider.upload(localURL: localFile, to: parent, named: "remote.txt")

        let upload = try XCTUnwrap(recorder.values.first { $0.url?.kodboxRoute == "explorer/upload/fileUpload" })
        XCTAssertFalse(taskID.uuidString.isEmpty)
        XCTAssertEqual(upload.httpMethod, "POST")
        XCTAssertTrue(upload.url?.path.hasSuffix("index.php") == true && upload.url?.kodboxRoute == "explorer/upload/fileUpload")
        XCTAssertTrue(upload.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertNotEqual(upload.url?.path, "/")
    }

    func testDownloadStreamsToTemporaryFileThenPublishesAtDestination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.txt")
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/index/fileOut":
                return Self.response(for: request, contentType: "application/octet-stream", data: Data("downloaded contents".utf8))
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())
        let item = RemotePath(identifier: "{source:5}/projects/report.txt", displayPath: "/Personal/projects/report.txt")

        _ = try await provider.download(item: item, to: destination)

        let download = try XCTUnwrap(recorder.values.first { $0.url?.kodboxRoute == "explorer/index/fileOut" })
        XCTAssertEqual(download.httpMethod, "GET")
        XCTAssertEqual(download.url?.queryValue(named: "path"), "{source:5}/projects/report.txt")
        XCTAssertEqual(download.url?.queryValue(named: "download"), "1")
        XCTAssertFalse(download.url?.queryValue(named: "path") == "/")
        XCTAssertEqual(try Data(contentsOf: destination), Data("downloaded contents".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["download.txt"])
    }

    func testDownloadDoesNotFailAfterTemporaryFileIsMovedToDestination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.txt")
        KodboxProviderURLProtocol.handler = { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/index/fileOut":
                return Self.response(for: request, contentType: "application/octet-stream", data: Data("downloaded contents".utf8))
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())

        let taskID = try await provider.download(
            item: .init(identifier: "{source:5}/projects/report.txt", displayPath: "/Personal/projects/report.txt"),
            to: destination
        )

        XCTAssertFalse(taskID.uuidString.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), Data("downloaded contents".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["download.txt"])
    }

    func testDownloadRejectsExistingDestinationWithoutRequest() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.txt")
        try Data("existing".utf8).write(to: destination)
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            throw KodboxProviderFixtureError.unexpectedRequest
        }
        let provider = KodboxProvider(session: makeSession())

        do {
            _ = try await provider.download(
                item: .init(identifier: "{source:5}/projects/report.txt", displayPath: "/Personal/projects/report.txt"),
                to: destination
            )
            XCTFail("Expected existing destination to be rejected")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testDownloadFailureLeavesNoDestinationOrTemporaryFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.txt")
        KodboxProviderURLProtocol.handler = { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/index/fileOut":
                return Self.response(for: request, status: 502, contentType: "text/plain", data: Data("failure".utf8))
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())

        do {
            _ = try await provider.download(
                item: .init(identifier: "{source:5}/projects/report.txt", displayPath: "/Personal/projects/report.txt"),
                to: destination
            )
            XCTFail("Expected failed download")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func makeSession() -> KodboxAPISession {
        KodboxAPISession(
            baseURL: URL(string: "https://kodbox.test/")!,
            credentials: .init(username: "alice", password: "pass"),
            session: KodboxHTTPClient.ephemeralSession(protocolClasses: [KodboxProviderURLProtocol.self])
        )
    }

    private static let optionsResponse = #"{"code":true,"data":{"version":"1.68.10","user":{"myhome":"{source:5}/","desktop":"{source:6}/"}}}"#

    private static func response(for request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        response(for: request, contentType: "application/json", data: Data(body.utf8))
    }

    private static func response(for request: URLRequest, status: Int = 200, contentType: String, data: Data) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!,
            data
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderKodboxProvider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private enum KodboxProviderFixtureError: Error {
    case unexpectedRequest
}

private final class KodboxProviderURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: KodboxProviderFixtureError.unexpectedRequest)
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

private final class KodboxProviderRequestRecorder: @unchecked Sendable {
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
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let httpBodyStream else { return nil }

        httpBodyStream.open()
        defer { httpBodyStream.close() }
        var buffer = [UInt8](repeating: 0, count: 1_024)
        var body = Data()
        while true {
            let bytesRead = httpBodyStream.read(&buffer, maxLength: buffer.count)
            guard bytesRead >= 0 else { return nil }
            guard bytesRead > 0 else { return body }
            body.append(buffer, count: bytesRead)
        }
    }

    var bodyFormValues: [String: String]? {
        guard let data = bodyData else { return nil }

        guard let body = String(data: data, encoding: .utf8) else { return nil }
        return URLComponents(string: "?\(body)")?.queryItems?.reduce(into: [:]) { result, item in
            result[item.name] = item.value
        }
    }
}
