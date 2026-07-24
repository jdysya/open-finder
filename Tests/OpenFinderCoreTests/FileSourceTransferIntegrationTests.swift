import Foundation
import XCTest
@testable import OpenFinderCore

final class FileSourceTransferIntegrationTests: XCTestCase {
    func testSupportedRelationMatrix() async throws {
        let fixture = try await FileSourceTransferFixture()
        defer { fixture.cleanup() }
        let accountID = UUID(uuidString: "24242424-2424-2424-2424-242424242424")!
        let remoteID = FileSourceID.remote(accountID: accountID, connectorID: .webDAV)

        XCTAssertEqual(
            FileRelationalCapabilities(source: .local, destination: remoteID).copy,
            .supported
        )
        XCTAssertEqual(
            FileRelationalCapabilities(source: remoteID, destination: .local).copy,
            .supported
        )
        XCTAssertEqual(
            FileRelationalCapabilities(source: remoteID, destination: remoteID).copy,
            .supported
        )

        let provider = TransferIntegrationRemoteProvider()
        await provider.store(Data("remote".utf8), at: "/source/remote.txt")
        let queue = try await fixture.makeQueue(accountProviders: [accountID: provider])

        let localCopy = try await fixture.enqueueCopy(
            on: queue,
            entries: [fixture.localEntry],
            source: .local(path: fixture.localSource.path),
            destination: .local(path: fixture.localDestination.path),
            label: "local-direct"
        )
        XCTAssertEqual(localCopy.status, .succeeded)
        XCTAssertEqual(localCopy.progressDetail?.completed, 1)
        XCTAssertEqual(localCopy.resultSummary, "Copied 1 item(s)")

        let upload = try await fixture.enqueueCopy(
            on: queue,
            entries: [fixture.uploadEntry],
            source: .local(path: fixture.uploadSource.path),
            destination: remoteLocation(accountID, path: "/upload"),
            label: "upload"
        )
        XCTAssertEqual(upload.status, .succeeded)

        let remoteEntry = await provider.entry(accountID: accountID, path: "/source/remote.txt")
        let materialize = try await fixture.enqueueCopy(
            on: queue,
            entries: [remoteEntry],
            source: remoteLocation(accountID, path: "/source"),
            destination: .local(path: fixture.materializedDestination.path),
            label: "materialize"
        )
        XCTAssertEqual(materialize.status, .succeeded)
        XCTAssertEqual(
            try Data(contentsOf: fixture.materializedDestination.appendingPathComponent("remote.txt")),
            Data("remote".utf8)
        )

        let serverSide = try await fixture.enqueueCopy(
            on: queue,
            entries: [remoteEntry],
            source: remoteLocation(accountID, path: "/source"),
            destination: remoteLocation(accountID, path: "/server-copy"),
            label: "server-side"
        )
        XCTAssertEqual(serverSide.status, .succeeded)

        let observables = await provider.observables()
        XCTAssertEqual(observables.uploadCount, 1)
        XCTAssertEqual(observables.downloadCount, 1)
        XCTAssertEqual(observables.copyCount, 1)
        XCTAssertTrue(
            observables.downloadDestinations.allSatisfy {
                $0.standardizedFileURL.path.hasPrefix(
                    fixture.materializationRoot.standardizedFileURL.path + "/"
                )
            }
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: fixture.materializationRoot,
                includingPropertiesForKeys: nil
            ),
            []
        )
    }

    func testCrossAccountAndRemoteOverwriteRemainRejected() async throws {
        let fixture = try await FileSourceTransferFixture()
        defer { fixture.cleanup() }
        let firstAccount = UUID(uuidString: "25252525-2525-2525-2525-252525252525")!
        let secondAccount = UUID(uuidString: "26262626-2626-2626-2626-262626262626")!
        let first = TransferIntegrationRemoteProvider()
        let second = TransferIntegrationRemoteProvider()
        await first.store(Data("remote".utf8), at: "/source/remote.txt")
        let entry = await first.entry(accountID: firstAccount, path: "/source/remote.txt")
        let queue = try await fixture.makeQueue(
            accountProviders: [firstAccount: first, secondAccount: second]
        )

        let crossAccount = try await fixture.enqueueCopy(
            on: queue,
            entries: [entry],
            source: remoteLocation(firstAccount, path: "/source"),
            destination: remoteLocation(secondAccount, path: "/destination"),
            label: "cross-account"
        )
        XCTAssertEqual(crossAccount.status, .failed)
        XCTAssertEqual(
            crossAccount.errorMessage,
            FileCapabilityUnsupportedReason.crossSource.localizedDescription
        )

        let overwrite = try await fixture.enqueueCopy(
            on: queue,
            entries: [entry],
            source: remoteLocation(firstAccount, path: "/source"),
            destination: remoteLocation(firstAccount, path: "/destination"),
            overwrite: .replaceExisting,
            label: "remote-overwrite"
        )
        XCTAssertEqual(overwrite.status, .failed)
        XCTAssertEqual(
            overwrite.errorMessage,
            FileCapabilityUnsupportedReason.remoteOverwrite.localizedDescription
        )

        let firstObservables = await first.observables()
        let secondObservables = await second.observables()
        XCTAssertEqual(firstObservables.effectCount, 0)
        XCTAssertEqual(secondObservables.effectCount, 0)
    }

    func testFailedMaterializationReleasesLeaseAndRetrySucceeds() async throws {
        let fixture = try await FileSourceTransferFixture()
        defer { fixture.cleanup() }
        let accountID = UUID(uuidString: "27272727-2727-2727-2727-272727272727")!
        let provider = TransferIntegrationRemoteProvider(failDownloadAfterWrite: true)
        await provider.store(Data("retry".utf8), at: "/source/retry.txt")
        let entry = await provider.entry(accountID: accountID, path: "/source/retry.txt")
        let queue = try await fixture.makeQueue(accountProviders: [accountID: provider])

        let failedID = try await fixture.enqueueCopyID(
            on: queue,
            entries: [entry],
            source: remoteLocation(accountID, path: "/source"),
            destination: .local(path: fixture.materializedDestination.path),
            label: "materialize-failure"
        )
        let failed = try await queue.waitForTerminalStatus(failedID, timeout: 2)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.materializedDestination
                    .appendingPathComponent("retry.txt").path
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: fixture.materializationRoot,
                includingPropertiesForKeys: nil
            ),
            []
        )

        await provider.setFailDownloadAfterWrite(false)
        let retryID = try await queue.retry(failedID)
        let retry = try await queue.waitForTerminalStatus(retryID, timeout: 2)
        XCTAssertEqual(retry.status, .succeeded)
        XCTAssertEqual(retry.descriptor?.lineage.attempt, 2)
        XCTAssertEqual(
            try Data(contentsOf: fixture.materializedDestination.appendingPathComponent("retry.txt")),
            Data("retry".utf8)
        )
    }
}

private struct FileSourceTransferFixture {
    let root: URL
    let localSource: URL
    let localDestination: URL
    let uploadSource: URL
    let materializedDestination: URL
    let materializationRoot: URL
    let localEntry: TransferEntrySnapshot
    let uploadEntry: TransferEntrySnapshot

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderFileSourceTransfer-\(UUID().uuidString)")
        localSource = root.appendingPathComponent("local-source", isDirectory: true)
        localDestination = root.appendingPathComponent("local-destination", isDirectory: true)
        uploadSource = root.appendingPathComponent("upload-source", isDirectory: true)
        materializedDestination = root.appendingPathComponent(
            "materialized-destination",
            isDirectory: true
        )
        materializationRoot = root.appendingPathComponent("materializations", isDirectory: true)
        try [localSource, localDestination, uploadSource, materializedDestination].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        let localFile = localSource.appendingPathComponent("local.txt")
        let uploadFile = uploadSource.appendingPathComponent("upload.txt")
        try Data("local".utf8).write(to: localFile)
        try Data("upload".utf8).write(to: uploadFile)
        let provider = LocalFileProvider()
        localEntry = TransferEntrySnapshot(
            try await provider.stat(.local(path: localFile.path))
        )
        uploadEntry = TransferEntrySnapshot(
            try await provider.stat(.local(path: uploadFile.path))
        )
    }

    func makeQueue(
        accountProviders: [UUID: TransferIntegrationRemoteProvider]
    ) async throws -> TaskQueueService {
        let providers = RemoteProviderRegistry { accountID, revision in
            guard let id = UUID(uuidString: accountID),
                  let provider = accountProviders[id]
            else {
                throw RemoteProviderRegistry.UnsupportedProviderError(
                    accountID: accountID,
                    revision: revision
                )
            }
            return provider
        }
        let sources = FileSourceRegistry(
            remoteProviderRegistry: providers,
            materializationRoot: materializationRoot
        )
        let handlers = TaskHandlerRegistry()
        try await handlers.register(TransferCopyTaskHandler(fileSources: sources).taskHandler)
        return TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: handlers)
    }

    func enqueueCopy(
        on queue: TaskQueueService,
        entries: [TransferEntrySnapshot],
        source: Location,
        destination: Location,
        overwrite: TransferOverwritePolicy = .rejectExisting,
        label: String
    ) async throws -> TaskRecord {
        let taskID = try await enqueueCopyID(
            on: queue,
            entries: entries,
            source: source,
            destination: destination,
            overwrite: overwrite,
            label: label
        )
        return try await queue.waitForTerminalStatus(taskID, timeout: 2)
    }

    func enqueueCopyID(
        on queue: TaskQueueService,
        entries: [TransferEntrySnapshot],
        source: Location,
        destination: Location,
        overwrite: TransferOverwritePolicy = .rejectExisting,
        label: String
    ) async throws -> UUID {
        let taskID = UUID()
        let envelope = TransferTaskEnvelope(
            entries: entries,
            source: source,
            destination: destination,
            overwrite: overwrite
        )
        let descriptor = try envelope.makeDescriptor(
            taskID: taskID,
            handlerID: .transferCopy,
            resourceKey: "transfer:\(label)",
            idempotencyKey: "transfer:\(label)",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: await queue.reserveQueueOrdinal()
        )
        return try await queue.enqueue(.init(
            kind: .localCopy,
            title: label,
            descriptor: descriptor
        ))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum TransferIntegrationFailure: Error {
    case downloadAfterWrite
}

private actor TransferIntegrationRemoteProvider: RemoteProvider {
    struct Observables: Sendable {
        let uploadCount: Int
        let downloadCount: Int
        let copyCount: Int
        let deleteCount: Int
        let downloadDestinations: [URL]

        var effectCount: Int {
            uploadCount + downloadCount + copyCount + deleteCount
        }
    }

    private var files: [String: Data] = [:]
    private var failDownloadAfterWrite: Bool
    private var uploadCount = 0
    private var downloadCount = 0
    private var copyCount = 0
    private var deleteCount = 0
    private var downloadDestinations: [URL] = []

    init(failDownloadAfterWrite: Bool = false) {
        self.failDownloadAfterWrite = failDownloadAfterWrite
    }

    func store(_ data: Data, at path: String) {
        files[path] = data
    }

    func setFailDownloadAfterWrite(_ value: Bool) {
        failDownloadAfterWrite = value
    }

    func entry(accountID: UUID, path: String) -> TransferEntrySnapshot {
        let data = files[path]!
        let name = URL(fileURLWithPath: path).lastPathComponent
        return TransferEntrySnapshot(FileItem(
            id: "remote:\(accountID.uuidString):\(path)",
            name: name,
            location: remoteLocation(accountID, path: path),
            kind: .file,
            size: Int64(data.count),
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: "text/plain",
            fileExtension: "txt",
            isHidden: false,
            isReadable: true,
            isWritable: true
        ))
    }

    func observables() -> Observables {
        Observables(
            uploadCount: uploadCount,
            downloadCount: downloadCount,
            copyCount: copyCount,
            deleteCount: deleteCount,
            downloadDestinations: downloadDestinations
        )
    }

    func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        let prefix = directory.identifier.hasSuffix("/")
            ? directory.identifier
            : directory.identifier + "/"
        let items = files.compactMap { path, data -> RemoteItem? in
            guard path.hasPrefix(prefix),
                  !path.dropFirst(prefix.count).contains("/")
            else {
                return nil
            }
            return RemoteItem(
                id: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: .init(identifier: path, displayPath: path),
                kind: .file,
                size: Int64(data.count),
                modificationDate: nil,
                etag: nil,
                mimeType: "text/plain",
                isReadable: true,
                isWritable: true
            )
        }
        return .init(
            current: directory,
            parent: nil,
            items: items,
            capabilities: .init(isReadable: true, isWritable: true)
        )
    }

    func createDirectory(in parent: RemotePath, named name: String) async throws {}

    func delete(item: RemotePath) async throws {
        deleteCount += 1
        files.removeValue(forKey: item.identifier)
    }

    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {
        guard let data = files.removeValue(forKey: item.identifier) else {
            throw OpenFinderError.itemNotFound(item.identifier)
        }
        files[join(destination, name)] = data
    }

    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {
        copyCount += 1
        guard let data = files[item.identifier] else {
            throw OpenFinderError.itemNotFound(item.identifier)
        }
        files[join(destination, name)] = data
    }

    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID {
        uploadCount += 1
        files[join(parent, name)] = try Data(contentsOf: localURL)
        return UUID()
    }

    func download(item: RemotePath, to localURL: URL) async throws -> TaskID {
        downloadCount += 1
        downloadDestinations.append(localURL)
        guard let data = files[item.identifier] else {
            throw OpenFinderError.itemNotFound(item.identifier)
        }
        try data.write(to: localURL)
        if failDownloadAfterWrite {
            throw TransferIntegrationFailure.downloadAfterWrite
        }
        return UUID()
    }

    private func join(_ parent: RemotePath, _ name: String) -> String {
        parent.identifier.hasSuffix("/")
            ? parent.identifier + name
            : parent.identifier + "/" + name
    }
}

private func remoteLocation(_ accountID: UUID, path: String) -> Location {
    .remote(.init(
        accountID: accountID,
        connectorID: .webDAV,
        path: .init(identifier: path, displayPath: path)
    ))
}
