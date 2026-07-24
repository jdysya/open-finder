import Foundation
import OpenFinderCore

enum FileTransferService {
    private static let transferCoordinator = TransferCoordinator()

    static func copyOrMove(
        _ items: [FileItem],
        from source: Location,
        to destination: Location,
        move: Bool,
        overwriteExisting: Bool = false,
        taskID: TaskID = UUID(),
        faultPoint: TransferCoordinator.FaultPoint? = nil,
        remoteProviderResolver: @escaping @Sendable (RemoteLocation) async throws -> any RemoteProvider,
        progress: (@Sendable (Double, String) async -> Void)? = nil
    ) async throws {
        let request = TransferRequest(
            taskID: taskID,
            operation: move ? .move : .copy,
            entries: items.map(TransferEntrySnapshot.init),
            source: source,
            destination: destination,
            overwrite: overwriteExisting ? .replaceExisting : .rejectExisting
        )
        let operations = transferOperations(
            source: source,
            remoteProviderResolver: remoteProviderResolver
        )
        try await transferCoordinator.execute(
            request,
            operations: operations,
            progress: { snapshot in
                await progress?(snapshot.fraction, snapshot.detail ?? "Transferring")
            },
            faultPoint: faultPoint
        )
    }

    private static func perform(
        _ items: [FileItem],
        from source: Location,
        to destination: Location,
        move: Bool,
        overwriteExisting: Bool,
        remoteProviderResolver: @escaping @Sendable (RemoteLocation) async throws -> any RemoteProvider
    ) async throws {
        if case .local = source, case .local = destination {
            let provider = LocalFileProvider()
            if move {
                _ = try await provider.move(
                    items,
                    to: destination,
                    overwriteExisting: overwriteExisting
                )
            } else {
                _ = try await provider.copy(
                    items,
                    to: destination,
                    overwriteExisting: overwriteExisting
                )
            }
            return
        }

        if case .local = source {
            let remoteDestination = try remoteLocation(for: destination)
            let remote = try await remoteProviderResolver(remoteDestination)
            let existingItems = Dictionary(uniqueKeysWithValues: try await remote
                .list(directory: remoteDestination.path).items.map { ($0.name, $0) })
            for item in items {
                guard let url = item.localURL else { continue }
                if existingItems[item.name] != nil {
                    throw OpenFinderError.operationFailed(
                        overwriteExisting
                            ? "Replacing existing remote items is not supported yet"
                            : "Remote destination already contains: \(item.name)"
                    )
                }
                try await upload(
                    localURL: url,
                    to: remoteDestination.path,
                    remote: remote
                )
            }
            if move { try await LocalFileProvider().trashOrDelete(items) }
            return
        }

        if case .local = destination {
            guard let destinationURL = destination.localURL else {
                throw OpenFinderError.unsupportedLocation(destination)
            }
            let remoteSource = try remoteLocation(for: source)
            let remote = try await remoteProviderResolver(remoteSource)
            for item in items {
                let remoteItem = try remoteLocation(for: item.location).path
                try await download(
                    remotePath: remoteItem,
                    kind: item.kind,
                    named: item.name,
                    to: try safeChildURL(
                        in: destinationURL,
                        named: item.name,
                        isDirectory: item.isDirectory
                    ),
                    remote: remote,
                    overwriteExisting: overwriteExisting
                )
                if move { try await remote.delete(item: remoteItem) }
            }
            return
        }

        let remoteSource = try remoteLocation(for: source)
        let remoteDestination = try remoteLocation(for: destination)
        guard remoteSource.accountID == remoteDestination.accountID,
              remoteSource.connectorID == remoteDestination.connectorID
        else {
            throw OpenFinderError.operationFailed(
                "Transferring directly between different remote accounts is not supported yet"
            )
        }
        let remote = try await remoteProviderResolver(remoteSource)
        let existingNames = Set(
            try await remote.list(directory: remoteDestination.path).items.map(\.name)
        )
        for item in items {
            if existingNames.contains(item.name) {
                throw OpenFinderError.operationFailed(
                    overwriteExisting
                        ? "Replacing existing remote items is not supported yet"
                        : "Remote destination already contains: \(item.name)"
                )
            }
            let remoteItem = try remoteLocation(for: item.location).path
            if move {
                try await remote.move(
                    item: remoteItem,
                    to: remoteDestination.path,
                    named: item.name
                )
            } else {
                try await remote.copy(
                    item: remoteItem,
                    to: remoteDestination.path,
                    named: item.name
                )
            }
        }
    }

    private static func transferOperations(
        source: Location,
        remoteProviderResolver: @escaping @Sendable (RemoteLocation) async throws -> any RemoteProvider
    ) -> TransferFileOperations {
        TransferFileOperations(
            snapshotSource: { entry in
                switch entry.location {
                case .local:
                    guard let url = entry.location.localURL,
                          FileManager.default.fileExists(atPath: url.path)
                    else {
                        return nil
                    }
                    return TransferEntrySnapshot(
                        try await LocalFileProvider().stat(entry.location)
                    )
                case .webDAV, .remote:
                    let directory = try remoteLocation(for: source)
                    let remote = try await remoteProviderResolver(directory)
                    let listing = try await remote.list(directory: directory.path)
                    guard let item = listing.items.first(where: {
                        $0.remotePath.identifier == remotePath(for: entry.location)?.identifier
                            || $0.name == entry.name
                    }) else {
                        return nil
                    }
                    return TransferEntrySnapshot(fileItem(item, at: directory))
                case .rclone:
                    throw OpenFinderError.unsupportedLocation(entry.location)
                }
            },
            snapshotDestination: { entry, destination in
                switch destination {
                case .local:
                    guard let directory = destination.localURL else {
                        throw OpenFinderError.unsupportedLocation(destination)
                    }
                    let target = try safeChildURL(
                        in: directory,
                        named: entry.name,
                        isDirectory: entry.item.isDirectory
                    )
                    guard FileManager.default.fileExists(atPath: target.path) else {
                        return nil
                    }
                    return TransferEntrySnapshot(
                        try await LocalFileProvider().stat(.local(path: target.path))
                    )
                case .webDAV, .remote:
                    let directory = try remoteLocation(for: destination)
                    let remote = try await remoteProviderResolver(directory)
                    let listing = try await remote.list(directory: directory.path)
                    guard let item = listing.items.first(where: { $0.name == entry.name }) else {
                        return nil
                    }
                    return TransferEntrySnapshot(fileItem(item, at: directory))
                case .rclone:
                    throw OpenFinderError.unsupportedLocation(destination)
                }
            },
            execute: { operation, entry, destination, overwrite in
                try await perform(
                    [entry.item],
                    from: source,
                    to: destination,
                    move: operation == .move,
                    overwriteExisting: overwrite == .replaceExisting,
                    remoteProviderResolver: remoteProviderResolver
                )
            }
        )
    }

    private static func remotePath(for location: Location) -> RemotePath? {
        switch location {
        case .remote(let remote):
            remote.path
        case .webDAV(_, let path):
            RemotePath(identifier: path, displayPath: path)
        case .local, .rclone:
            nil
        }
    }

    private static func fileItem(
        _ item: RemoteItem,
        at location: RemoteLocation
    ) -> FileItem {
        FileItem(
            id: "remote:\(location.accountID.uuidString):\(item.remotePath.identifier)",
            name: item.name,
            location: .remote(.init(
                accountID: location.accountID,
                connectorID: location.connectorID,
                path: item.remotePath
            )),
            kind: item.kind,
            size: item.size,
            modificationDate: item.modificationDate,
            creationDate: nil,
            uti: nil,
            mimeType: item.mimeType,
            fileExtension: URL(fileURLWithPath: item.name).pathExtension.isEmpty
                ? nil
                : URL(fileURLWithPath: item.name).pathExtension.lowercased(),
            isHidden: item.name.hasPrefix("."),
            isReadable: item.isReadable,
            isWritable: item.isWritable,
            tags: item.tags,
            tagScopes: item.tagScopes,
            supportsTagEditing: item.supportsTagEditing
        )
    }

    private static func remoteLocation(for location: Location) throws -> RemoteLocation {
        switch location {
        case .remote(let remoteLocation):
            return remoteLocation
        case .webDAV(let accountID, let path):
            return .init(
                accountID: accountID,
                connectorID: .webDAV,
                path: .init(identifier: path, displayPath: path)
            )
        case .local, .rclone:
            throw OpenFinderError.unsupportedLocation(location)
        }
    }

    private static func upload(
        localURL: URL,
        to parent: RemotePath,
        remote: any RemoteProvider
    ) async throws {
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            let name = localURL.lastPathComponent
            try await remote.createDirectory(in: parent, named: name)
            let listing = try await remote.list(directory: parent)
            guard let created = listing.items.first(where: {
                $0.name == name && $0.kind == .directory
            }) else {
                throw OpenFinderError.operationFailed(
                    "Remote directory was not visible after creation: \(name)"
                )
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: localURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            for child in children {
                try await upload(localURL: child, to: created.remotePath, remote: remote)
            }
        } else {
            _ = try await remote.upload(
                localURL: localURL,
                to: parent,
                named: localURL.lastPathComponent
            )
        }
    }
}
