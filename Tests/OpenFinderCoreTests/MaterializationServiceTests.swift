import Foundation
import XCTest
@testable import OpenFinderCore

final class MaterializationServiceTests: XCTestCase {
    func testMaterializePublishesDistinctLeasesForSameNamedFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MaterializationService(root: root)
        let provider = MaterializationServiceProvider(result: .success(Data("movie".utf8)))
        let first = MaterializationRequest(
            sourceID: .remote(
                accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                connectorID: .kodbox
            ),
            path: .init(identifier: "{source:one}/movie.mp4", displayPath: "/one/movie.mp4"),
            requestID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let second = MaterializationRequest(
            sourceID: .remote(
                accountID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                connectorID: .kodbox
            ),
            path: .init(identifier: "{source:two}/movie.mp4", displayPath: "/two/movie.mp4"),
            requestID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        async let firstLease = service.materialize(first, provider: provider)
        async let secondLease = service.materialize(second, provider: provider)
        let leases = try await [firstLease, secondLease]

        XCTAssertNotEqual(leases[0].url, leases[1].url)
        XCTAssertEqual(try Data(contentsOf: leases[0].url), Data("movie".utf8))
        XCTAssertEqual(try Data(contentsOf: leases[1].url), Data("movie".utf8))
        XCTAssertFalse(leases.contains { $0.url.lastPathComponent.hasPrefix(".partial-") })
        try leases.forEach { try $0.release() }
    }

    func testMaterializeFailureDoesNotPublishOrDeleteAnotherLease() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MaterializationService(root: root)
        let stableProvider = MaterializationServiceProvider(result: .success(Data("stable".utf8)))
        let stableLease = try await service.materialize(
            request(identifier: "stable", name: "movie.mp4", requestID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            provider: stableProvider
        )
        let failingProvider = MaterializationServiceProvider(result: .failure)

        do {
            _ = try await service.materialize(
                request(identifier: "failing", name: "movie.mp4", requestID: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
                provider: failingProvider
            )
            XCTFail("Expected download failure")
        } catch MaterializationServiceProvider.Failure.download {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: stableLease.url.path))
        XCTAssertEqual(try Data(contentsOf: stableLease.url), Data("stable".utf8))
        XCTAssertEqual(
            try namespaces(in: root).map { $0.resolvingSymlinksInPath() },
            [try XCTUnwrap(stableLease.ownedNamespaceURL).resolvingSymlinksInPath()]
        )
        try stableLease.release()
        XCTAssertTrue(try namespaces(in: root).isEmpty)
    }

    func testMaterializePublishesOnlyAfterPartialDownloadCompletes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MaterializationService(root: root)
        let provider = SuspendingMaterializationServiceProvider()
        let request = request(
            identifier: "staged",
            name: "movie.mp4",
            requestID: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        )
        let task = Task { try await service.materialize(request, provider: provider) }

        await provider.waitUntilDownloadStarts()
        let namespace = try XCTUnwrap(try namespaces(in: root).only)
        let stagedFiles = try FileManager.default.contentsOfDirectory(atPath: namespace.path)
        XCTAssertEqual(stagedFiles.count, 1)
        XCTAssertTrue(stagedFiles[0].hasPrefix(".partial-"))

        await provider.finish()
        let lease = try await task.value
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("published".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: namespace.path),
            [lease.url.lastPathComponent]
        )
        try lease.release()
    }

    private func request(identifier: String, name: String, requestID: String) -> MaterializationRequest {
        MaterializationRequest(
            sourceID: .remote(
                accountID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                connectorID: .kodbox
            ),
            path: .init(identifier: identifier, displayPath: "/(name)"),
            requestID: UUID(uuidString: requestID)!
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderMaterializationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func namespaces(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private actor MaterializationServiceProvider: RemoteProvider {
    enum Failure: Error {
        case download
    }

    enum Result {
        case success(Data)
        case failure
    }

    private let result: Result

    init(result: Result) {
        self.result = result
    }

    func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        .init(
            current: directory,
            parent: nil,
            items: [],
            capabilities: .init(isReadable: true, isWritable: true)
        )
    }

    func createDirectory(in parent: RemotePath, named name: String) async throws {}
    func delete(item: RemotePath) async throws {}
    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID { UUID() }

    func download(item: RemotePath, to localURL: URL) async throws -> TaskID {
        switch result {
        case .success(let data):
            try data.write(to: localURL)
            return UUID()
        case .failure:
            try Data("partial".utf8).write(to: localURL)
            throw Failure.download
        }
    }
}

private actor SuspendingMaterializationServiceProvider: RemoteProvider {
    private var started = false
    private var finished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilDownloadStarts() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        finished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        .init(
            current: directory,
            parent: nil,
            items: [],
            capabilities: .init(isReadable: true, isWritable: true)
        )
    }

    func createDirectory(in parent: RemotePath, named name: String) async throws {}
    func delete(item: RemotePath) async throws {}
    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID { UUID() }

    func download(item: RemotePath, to localURL: URL) async throws -> TaskID {
        try Data("partial".utf8).write(to: localURL)
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !finished {
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        try Data("published".utf8).write(to: localURL)
        return UUID()
    }
}
