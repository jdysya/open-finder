import Foundation
import OpenFinderCore

enum FileTransferService {
    static func copyOrMove(
        _ items: [FileItem],
        from source: Location,
        to destination: Location,
        move: Bool,
        overwriteExisting: Bool = false,
        remoteProviderResolver: @escaping @Sendable (RemoteLocation) async throws -> any RemoteProvider,
        progress: (@Sendable (Double, String) -> Void)? = nil
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
            for (index, item) in items.enumerated() {
                guard let url = item.localURL else { continue }
                if existingItems[item.name] != nil {
                    throw OpenFinderError.operationFailed(
                        overwriteExisting
                            ? "Replacing existing remote items is not supported yet"
                            : "Remote destination already contains: \(item.name)"
                    )
                }
                progress?(
                    Double(index) / Double(max(items.count, 1)),
                    "Uploading \(item.name)"
                )
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
            for (index, item) in items.enumerated() {
                let remoteItem = try remoteLocation(for: item.location).path
                progress?(
                    Double(index) / Double(max(items.count, 1)),
                    "Downloading \(item.name)"
                )
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
        for (index, item) in items.enumerated() {
            if existingNames.contains(item.name) {
                throw OpenFinderError.operationFailed(
                    overwriteExisting
                        ? "Replacing existing remote items is not supported yet"
                        : "Remote destination already contains: \(item.name)"
                )
            }
            let remoteItem = try remoteLocation(for: item.location).path
            progress?(
                Double(index) / Double(max(items.count, 1)),
                "Transferring \(item.name)"
            )
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
