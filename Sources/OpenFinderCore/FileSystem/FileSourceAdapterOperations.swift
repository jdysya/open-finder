import Foundation

public struct FileSourceListing: Sendable {
    public let items: [FileItem]
    public let capabilities: FileListingCapabilities
    public let parent: Location?
    public let providerRevision: String

    public init(
        items: [FileItem],
        capabilities: FileListingCapabilities,
        parent: Location?,
        providerRevision: String
    ) {
        self.items = items
        self.capabilities = capabilities
        self.parent = parent
        self.providerRevision = providerRevision
    }
}

public extension ResolvedFileSource {
    func list(options: FileListOptions = .init()) async throws -> FileSourceListing {
        switch adapter {
        case .local(let adapter):
            let items = try await adapter.provider.list(location.location, options: options)
            let url = URL(fileURLWithPath: location.path.identifier).standardizedFileURL
            let parent = url.path == "/"
                ? nil
                : Location.local(path: url.deletingLastPathComponent().path)
            return .init(
                items: items,
                capabilities: .init(
                    source: capabilities,
                    isReadable: true,
                    isWritable: true,
                    supportsTags: true
                ),
                parent: parent,
                providerRevision: "local"
            )
        case .remote(let adapter):
            let listing = try await adapter.provider.list(directory: location.path)
            guard let remoteLocation = location.remoteLocation else {
                preconditionFailure("Remote adapter must have a remote location")
            }
            return .init(
                items: try listing.items.map {
                    try Self.fileItem($0, sourceID: location.sourceID)
                },
                capabilities: effectiveCapabilities(for: listing.capabilities),
                parent: listing.parent.map {
                    .remote(.init(
                        accountID: remoteLocation.accountID,
                        connectorID: remoteLocation.connectorID,
                        path: $0
                    ))
                },
                providerRevision: adapter.revision
            )
        }
    }

    func createFolder(named name: String) async throws {
        switch adapter {
        case .local(let adapter):
            try await adapter.provider.createFolder(at: location.location, name: name)
        case .remote(let adapter):
            try await adapter.provider.createDirectory(in: location.path, named: name)
        }
    }

    func availableName(_ base: String) -> String {
        guard case .local = adapter else { return base }
        let root = URL(fileURLWithPath: location.path.identifier)
        let fileExtension = URL(fileURLWithPath: base).pathExtension
        let stem = fileExtension.isEmpty
            ? base
            : String(base.dropLast(fileExtension.count + 1))
        var candidate = base
        var index = 2
        while FileManager.default.fileExists(
            atPath: root.appendingPathComponent(candidate).path
        ) {
            candidate = fileExtension.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(fileExtension)"
            index += 1
        }
        return candidate
    }

    func createFile(named name: String) async throws {
        switch adapter {
        case .local(let adapter):
            try await adapter.provider.createFile(at: location.location, name: name)
        case .remote(let adapter):
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenFinder-empty-\(UUID().uuidString)")
            guard FileManager.default.createFile(
                atPath: temporaryURL.path,
                contents: Data()
            ) else {
                throw OpenFinderError.operationFailed("Could not create temporary file")
            }
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            _ = try await adapter.provider.upload(
                localURL: temporaryURL,
                to: location.path,
                named: name
            )
        }
    }

    func rename(
        _ item: FileItem,
        to name: String,
        in destination: ResolvedFileSource
    ) async throws {
        guard location.sourceID == destination.location.sourceID else {
            throw FileCapabilityUnsupportedReason.crossSource
        }
        switch adapter {
        case .local(let adapter):
            _ = try await adapter.provider.rename(item, to: name)
        case .remote(let adapter):
            let itemLocation = try item.location.resolvedFileLocation
            try await adapter.provider.move(
                item: itemLocation.path,
                to: destination.location.path,
                named: name
            )
        }
    }

    func delete(_ item: FileItem) async throws {
        switch adapter {
        case .local(let adapter):
            try await adapter.provider.trashOrDelete([item])
        case .remote(let adapter):
            try await adapter.provider.delete(
                item: try item.location.resolvedFileLocation.path
            )
        }
    }

    var tagProvider: (any TagProvider)? {
        switch adapter {
        case .local(let adapter):
            adapter.provider
        case .remote(let adapter):
            adapter.provider as? any TagProvider
        }
    }

    func download(_ item: FileItem, to destination: URL) async throws {
        switch adapter {
        case .local:
            guard let sourceURL = item.localURL else {
                throw OpenFinderError.unsupportedLocation(item.location)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        case .remote(let adapter):
            let itemLocation = try item.location.resolvedFileLocation
            _ = try await adapter.provider.download(item: itemLocation.path, to: destination)
        }
    }

    private static func fileItem(
        _ item: RemoteItem,
        sourceID: FileSourceID
    ) throws -> FileItem {
        guard case .remote(let accountID, _) = sourceID else {
            throw OpenFinderError.operationFailed(
                "Remote item cannot be associated with a local source"
            )
        }
        let location = FileLocation(sourceID: sourceID, path: item.remotePath).location
        return FileItem(
            id: "remote:\(accountID.uuidString):\(item.remotePath.identifier)",
            name: item.name,
            location: location,
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
}

public extension FileLocation {
    var location: Location {
        switch sourceID {
        case .local:
            return .local(path: path.identifier)
        case .remote(let accountID, let connectorID):
            return .remote(.init(
                accountID: accountID,
                connectorID: connectorID,
                path: path
            ))
        }
    }

    var remoteLocation: RemoteLocation? {
        guard case .remote(let accountID, let connectorID) = sourceID else {
            return nil
        }
        return .init(accountID: accountID, connectorID: connectorID, path: path)
    }

}

public extension Location {
    var resolvedFileLocation: FileLocation {
        get throws {
            switch fileLocation {
            case .resolved(let location):
                return location
            case .unsupported(let reason):
                throw reason
            }
        }
    }
}
