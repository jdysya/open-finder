import Foundation

extension TransferRegistryIO {
    static func upload(
        _ localURL: URL,
        to parent: RemotePath,
        remote: any RemoteProvider
    ) async throws {
        let isDirectory = try localURL.resourceValues(
            forKeys: [.isDirectoryKey]
        ).isDirectory == true
        guard isDirectory else {
            _ = try await remote.upload(
                localURL: localURL,
                to: parent,
                named: localURL.lastPathComponent
            )
            return
        }
        try await remote.createDirectory(in: parent, named: localURL.lastPathComponent)
        let listing = try await remote.list(directory: parent)
        guard let created = listing.items.first(where: {
            $0.name == localURL.lastPathComponent && $0.kind == .directory
        }) else {
            throw OpenFinderError.operationFailed(
                "Remote directory was not visible after creation"
            )
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: localURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            try await upload(child, to: created.remotePath, remote: remote)
        }
    }

    static func download(
        _ remotePath: RemotePath,
        kind: FileKind,
        named name: String,
        to destination: URL,
        remote: any RemoteProvider,
        overwrite: TransferOverwritePolicy
    ) async throws {
        if kind == .directory || kind == .package {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw OpenFinderError.operationFailed(
                    "Replacing existing local directories is not supported"
                )
            }
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
            let listing = try await remote.list(directory: remotePath)
            for child in listing.items {
                try await download(
                    child.remotePath,
                    kind: child.kind,
                    named: child.name,
                    to: try safeChildURL(
                        in: destination,
                        named: child.name,
                        isDirectory: child.kind == .directory || child.kind == .package
                    ),
                    remote: remote,
                    overwrite: .rejectExisting
                )
            }
            return
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            _ = try await remote.download(item: remotePath, to: destination)
            return
        }
        guard overwrite == .replaceExisting else {
            throw OpenFinderError.operationFailed("Local destination already contains: \(name)")
        }
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".openfinder-transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await remote.download(item: remotePath, to: staged)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staged, to: destination)
    }

    static func safeChildURL(
        in parent: URL,
        named name: String,
        isDirectory: Bool
    ) throws -> URL {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\")
        else {
            throw OpenFinderError.invalidFileName(name)
        }
        return parent.appendingPathComponent(name, isDirectory: isDirectory)
    }

    static func fileItem(
        _ item: RemoteItem,
        sourceID: FileSourceID
    ) throws -> FileItem {
        guard case .remote(let accountID, let connectorID) = sourceID else {
            throw FileCapabilityUnsupportedReason.operationUnsupported(
                sourceID: sourceID,
                capability: .copy
            )
        }
        return FileItem(
            id: "remote:\(accountID.uuidString):\(item.remotePath.identifier)",
            name: item.name,
            location: .remote(.init(
                accountID: accountID,
                connectorID: connectorID,
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

    static func location(_ value: FileLocation) -> Location {
        switch value.sourceID {
        case .local:
            .local(path: value.path.identifier)
        case .remote(let accountID, let connectorID):
            .remote(.init(
                accountID: accountID,
                connectorID: connectorID,
                path: value.path
            ))
        }
    }
}

extension Location {
    var remotePath: RemotePath? {
        switch self {
        case .webDAV(_, let path):
            .init(identifier: path, displayPath: path)
        case .remote(let location):
            location.path
        case .local, .rclone:
            nil
        }
    }
}
