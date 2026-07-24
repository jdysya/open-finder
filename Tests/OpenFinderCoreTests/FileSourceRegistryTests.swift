import Foundation
import XCTest
@testable import OpenFinderCore

final class FileSourceRegistryTests: XCTestCase {
    private let webDAVAccountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let kodboxAccountID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testResolvesAdaptersAndCapabilities() async throws {
        let factory = FileSourceProviderFactory()
        let registry = makeRegistry(factory: factory)

        let local = try await registry.resolve(
            .local(path: FileManager.default.temporaryDirectory.path)
        )
        XCTAssertEqual(local.location.sourceID, .local)
        XCTAssertTrue(local.adapter.isLocal)
        XCTAssertEqual(
            local.capabilities.supportedIDs,
            Set(FileCapability.allCases)
        )

        let legacyWebDAV = try await registry.resolve(
            .webDAV(accountID: webDAVAccountID, path: "/legacy"),
            revision: "webdav-r1"
        )
        XCTAssertEqual(
            legacyWebDAV.location,
            FileLocation(
                sourceID: .remote(accountID: webDAVAccountID, connectorID: .webDAV),
                path: .init(identifier: "/legacy", displayPath: "/legacy")
            )
        )
        XCTAssertTrue(legacyWebDAV.adapter.isRemote(connectorID: .webDAV))
        XCTAssertEqual(
            legacyWebDAV.capabilities.supportedIDs,
            [.list, .read, .create, .delete, .copy, .move, .materialize]
        )

        let kodbox = try await registry.resolve(
            .remote(.init(
                accountID: kodboxAccountID,
                connectorID: .kodbox,
                path: .init(identifier: "{source:1}", displayPath: "/")
            )),
            revision: "kodbox-r1"
        )
        XCTAssertTrue(kodbox.adapter.isRemote(connectorID: .kodbox))
        XCTAssertEqual(
            kodbox.capabilities.supportedIDs,
            [.list, .read, .create, .delete, .copy, .move, .tags, .materialize]
        )
        XCTAssertFalse(kodbox.capabilities[.atomicPublish].isSupported)
        print(
            "CAPABILITIES local=\(local.capabilities.supportedIDs.map(\.rawValue).sorted()) " +
            "webdav=\(legacyWebDAV.capabilities.supportedIDs.map(\.rawValue).sorted()) " +
            "kodbox=\(kodbox.capabilities.supportedIDs.map(\.rawValue).sorted())"
        )
    }

    func testRevisionInvalidationAndUnsupportedSource() async throws {
        let factory = FileSourceProviderFactory()
        let registry = makeRegistry(factory: factory)
        let location = Location.remote(.init(
            accountID: webDAVAccountID,
            connectorID: .webDAV,
            path: .init(identifier: "/photos", displayPath: "/photos")
        ))

        let first = try await registry.resolve(location, revision: "r1")
        let cached = try await registry.resolve(location, revision: "r1")
        XCTAssertTrue(hasSameRemoteProvider(first.adapter, cached.adapter))

        await registry.invalidate(accountID: webDAVAccountID, revision: "r1")
        let invalidated = try await registry.resolve(location, revision: "r1")
        XCTAssertFalse(hasSameRemoteProvider(first.adapter, invalidated.adapter))

        let revised = try await registry.resolve(location, revision: "r2")
        XCTAssertFalse(hasSameRemoteProvider(invalidated.adapter, revised.adapter))

        let rcloneID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        await XCTAssertThrowsTypedError(
            try await registry.resolve(.rclone(remoteID: rcloneID, path: "archive:"))
        ) {
            XCTAssertEqual($0, .legacyRclone(remoteID: rcloneID))
        }

        await XCTAssertThrowsTypedError(
            try await registry.resolve(.remote(.init(
                accountID: webDAVAccountID,
                connectorID: "unknown",
                path: .init(identifier: "/", displayPath: "/")
            )), revision: "r1")
        ) {
            XCTAssertEqual($0, .unknownSource(connectorID: "unknown"))
        }

        let rejectingRegistry = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { accountID, revision in
                throw RemoteProviderRegistry.UnsupportedProviderError(
                    accountID: accountID,
                    revision: revision
                )
            }
        )
        do {
            _ = try await rejectingRegistry.resolve(location, revision: "unsupported-r1")
            XCTFail("Expected the provider registry's typed error")
        } catch let error as RemoteProviderRegistry.UnsupportedProviderError {
            XCTAssertEqual(
                error,
                .init(
                    accountID: webDAVAccountID.uuidString,
                    revision: "unsupported-r1"
                )
            )
        }
        print(
            "INVALIDATION staleRevisionEvicted=true revisedProviderDistinct=true " +
            "typedRclone=true typedUnknown=true typedProviderError=true"
        )
    }

    func testMaterializationLeaseReleasesOnlyOwnedNamespaceAndIsIdempotent() async throws {
        let factory = FileSourceProviderFactory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderRegistryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let retained = root.appendingPathComponent("retained.txt")
        try Data("keep".utf8).write(to: retained)
        let registry = FileSourceRegistry(
            localProvider: LocalFileProvider(),
            remoteProviderRegistry: RemoteProviderRegistry { accountID, revision in
                await factory.make(accountID: accountID, revision: revision)
            },
            materializationRoot: root
        )
        let localFile = root.appendingPathComponent("local.txt")
        try Data("local".utf8).write(to: localFile)
        let localLease = try await registry.materialize(.local(path: localFile.path))
        try localLease.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: localFile.path))
        XCTAssertNil(localLease.ownedNamespaceURL)

        let location = Location.remote(.init(
            accountID: kodboxAccountID,
            connectorID: .kodbox,
            path: .init(identifier: "{source:1}/movie.mp4", displayPath: "/movie.mp4")
        ))

        let lease = try await registry.materialize(location, revision: "r1")
        let namespace = try XCTUnwrap(lease.ownedNamespaceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: namespace.path))

        try lease.release()
        try lease.release()

        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertTrue(lease.isReleased)
        print("LEASE localPreserved=true ownedNamespaceRemoved=true siblingPreserved=true idempotent=true")
    }

    func testCancelledMaterializationCleansItsNamespaceWhenProviderFinishesNormally() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderRegistryCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localFile = root.appendingPathComponent("local.txt")
        try Data("local".utf8).write(to: localFile)
        let stableProvider = FileSourceTestRemoteProvider(identity: "stable")
        let stableRegistry = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { _, _ in stableProvider },
            materializationRoot: root
        )
        let stableLease = try await stableRegistry.materialize(
            remoteLocation(identifier: "stable", name: "stable.txt"),
            revision: "r1"
        )
        let stableNamespace = try XCTUnwrap(stableLease.ownedNamespaceURL)
        let cancelledLocation = remoteLocation(
            identifier: "cancelled",
            name: "cancelled.txt"
        )

        for _ in 0..<2 {
            let provider = CancellationIgnoringRemoteProvider()
            let registry = FileSourceRegistry(
                remoteProviderRegistry: RemoteProviderRegistry { _, _ in provider },
                materializationRoot: root
            )
            let cancelled = Task {
                try await registry.materialize(
                    cancelledLocation,
                    revision: "r1"
                )
            }
            await provider.waitUntilCancelledDownloadStarts()
            cancelled.cancel()
            await provider.finishCancelledDownload()

            do {
                _ = try await cancelled.value
                XCTFail("A cancelled materialization must not return a live lease")
            } catch is CancellationError {}

            let remainingDirectories = try FileManager.default
                .contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey]
                )
                .filter {
                    try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                }
            XCTAssertEqual(
                remainingDirectories.map { $0.resolvingSymlinksInPath() },
                [stableNamespace.resolvingSymlinksInPath()]
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stableLease.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localFile.path))
        try stableLease.release()
        print(
            "CANCELLATION noLeaseReturned=true cancelledNamespaceRemoved=true " +
            "stableLeasePreserved=true localPreserved=true repeatedInterruptions=2"
        )
    }

    private func makeRegistry(factory: FileSourceProviderFactory) -> FileSourceRegistry {
        FileSourceRegistry(
            localProvider: LocalFileProvider(),
            remoteProviderRegistry: RemoteProviderRegistry { accountID, revision in
                await factory.make(accountID: accountID, revision: revision)
            }
        )
    }

    private func remoteLocation(identifier: String, name: String) -> Location {
        .remote(.init(
            accountID: kodboxAccountID,
            connectorID: .kodbox,
            path: .init(identifier: identifier, displayPath: "/\(name)")
        ))
    }
}

private actor FileSourceProviderFactory {
    private var count = 0

    func make(accountID: String, revision: String) -> any RemoteProvider {
        count += 1
        return FileSourceTestRemoteProvider(
            identity: "\(accountID)-\(revision)-\(count)"
        )
    }
}

private actor FileSourceTestRemoteProvider: RemoteProvider {
    let identity: String

    init(identity: String) {
        self.identity = identity
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

    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID {
        UUID()
    }

    func download(item: RemotePath, to localURL: URL) async throws -> TaskID {
        try Data(identity.utf8).write(to: localURL)
        return UUID()
    }
}

private actor CancellationIgnoringRemoteProvider: RemoteProvider {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilCancelledDownloadStarts() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishCancelledDownload() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
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

    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID {
        UUID()
    }

    func download(item: RemotePath, to localURL: URL) async throws -> TaskID {
        if item.identifier == "cancelled" {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !released {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        try Data(item.identifier.utf8).write(to: localURL)
        return UUID()
    }
}

private func hasSameRemoteProvider(
    _ first: FileSourceAdapter,
    _ second: FileSourceAdapter
) -> Bool {
    guard case .remote(let firstAdapter) = first,
          case .remote(let secondAdapter) = second
    else {
        return false
    }
    return (firstAdapter.provider as AnyObject) ===
        (secondAdapter.provider as AnyObject)
}

private func XCTAssertThrowsTypedError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ assertions: (FileCapabilityUnsupportedReason) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected a typed unsupported-source error", file: file, line: line)
    } catch let error as FileCapabilityUnsupportedReason {
        assertions(error)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
