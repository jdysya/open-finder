import Foundation
@testable import OpenFinderCore

func makeRemoteQueue(
    provider: FakeMoveRemoteProvider,
    localProvider: LocalFileProvider = LocalFileProvider()
) async throws -> TaskQueueService {
    let remoteProviders = RemoteProviderRegistry { _, _ in provider }
    let fileSources = FileSourceRegistry(
        localProvider: localProvider,
        remoteProviderRegistry: remoteProviders
    )
    let handlers = TaskHandlerRegistry()
    try await handlers.register(
        TransferMoveTaskHandler(fileSources: fileSources).taskHandler
    )
    return TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: handlers)
}

func makeRemoteDescriptor(
    accountID: UUID,
    entry: TransferEntrySnapshot,
    destination: String,
    taskID: UUID
) throws -> TaskDescriptorEnvelope {
    try TransferTaskEnvelope(
        entries: [entry],
        source: remoteLocation(accountID: accountID, path: "/source"),
        destination: remoteLocation(accountID: accountID, path: destination),
        overwrite: .rejectExisting
    ).makeDescriptor(
        taskID: taskID,
        handlerID: .transferMove,
        resourceKey: "move:remote",
        idempotencyKey: "move:remote",
        lineage: .init(rootTaskID: taskID),
        queueOrdinal: 1
    )
}

func remoteEntry(
    accountID: UUID,
    path: String,
    provider: FakeMoveRemoteProvider
) async -> TransferEntrySnapshot {
    let stored = await provider.file(at: path)!
    let name = URL(fileURLWithPath: path).lastPathComponent
    return TransferEntrySnapshot(FileItem(
        id: "remote:\(accountID.uuidString):\(path)",
        name: name,
        location: remoteLocation(accountID: accountID, path: path),
        kind: .file,
        size: Int64(stored.data.count),
        modificationDate: stored.modifiedAt,
        creationDate: nil,
        uti: nil,
        mimeType: "text/plain",
        fileExtension: "txt",
        isHidden: false,
        isReadable: true,
        isWritable: true
    ))
}

func remoteLocation(accountID: UUID, path: String) -> Location {
    .remote(.init(
        accountID: accountID,
        connectorID: .webDAV,
        path: .init(identifier: path, displayPath: path)
    ))
}

struct MoveHandlerFixture {
    let root: URL
    let source: URL
    let destination: URL
    let sourceFile: URL
    let destinationFile: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderMoveHandler-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        sourceFile = source.appendingPathComponent("item.txt")
        destinationFile = destination.appendingPathComponent("item.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try Data("original".utf8).write(to: sourceFile)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

enum FakeMoveRemoteFault: Error {
    case afterEffect
}

actor FakeMoveRemoteProvider: RemoteProvider {
    struct StoredFile: Sendable {
        let data: Data
        let modifiedAt: Date
    }

    struct Observables: Sendable {
        let files: [String: Data]
        let moveCount: Int
        let deleteCount: Int
        let downloadCount: Int
        let uploadCount: Int
    }

    private var storage: [String: StoredFile] = [:]
    private var moveCount = 0
    private var deleteCount = 0
    private var downloadCount = 0
    private var uploadCount = 0
    private let deleteFault: FakeMoveRemoteFault?

    init(deleteFault: FakeMoveRemoteFault? = nil) {
        self.deleteFault = deleteFault
    }

    func store(_ data: Data, at path: String, modifiedAt: Date) {
        storage[path] = StoredFile(data: data, modifiedAt: modifiedAt)
    }

    func file(at path: String) -> StoredFile? {
        storage[path]
    }

    func observables() -> Observables {
        Observables(
            files: storage.mapValues(\.data),
            moveCount: moveCount,
            deleteCount: deleteCount,
            downloadCount: downloadCount,
            uploadCount: uploadCount
        )
    }

    func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        let prefix = directory.identifier.hasSuffix("/")
            ? directory.identifier
            : directory.identifier + "/"
        let items = storage
            .filter { path, _ in
                guard path.hasPrefix(prefix) else { return false }
                return !path.dropFirst(prefix.count).contains("/")
            }
            .map { path, stored in
                RemoteItem(
                    id: path,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    path: .init(identifier: path, displayPath: path),
                    kind: .file,
                    size: Int64(stored.data.count),
                    modificationDate: stored.modifiedAt,
                    etag: nil,
                    mimeType: "text/plain",
                    isReadable: true,
                    isWritable: true
                )
            }
        return RemoteDirectoryListing(
            current: directory,
            parent: nil,
            items: items,
            capabilities: .init(isReadable: true, isWritable: true)
        )
    }

    func createDirectory(in parent: RemotePath, named name: String) async throws {}

    func delete(item: RemotePath) async throws {
        deleteCount += 1
        storage.removeValue(forKey: item.identifier)
        if deleteFault == .afterEffect {
            throw FakeMoveRemoteFault.afterEffect
        }
    }

    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {
        moveCount += 1
        guard let stored = storage.removeValue(forKey: item.identifier) else {
            throw OpenFinderError.itemNotFound(item.identifier)
        }
        storage[join(destination.identifier, name)] = stored
    }

    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {
        guard let stored = storage[item.identifier] else {
            throw OpenFinderError.itemNotFound(item.identifier)
        }
        storage[join(destination.identifier, name)] = stored
    }

    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID {
        uploadCount += 1
        storage[join(parent.identifier, name)] = StoredFile(
            data: try Data(contentsOf: localURL),
            modifiedAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        return UUID()
    }

    func download(item: RemotePath, to localURL: URL) async throws -> TaskID {
        guard let stored = storage[item.identifier] else {
            throw OpenFinderError.itemNotFound(item.identifier)
        }
        downloadCount += 1
        try stored.data.write(to: localURL)
        return UUID()
    }

    private func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
