import Foundation

public enum FileSourceID: Codable, Hashable, Sendable {
    case local
    case remote(accountID: UUID, connectorID: RemoteConnectorID)

    public var isRemote: Bool {
        if case .remote = self { true } else { false }
    }
}

public struct FileLocation: Codable, Hashable, Sendable {
    public let sourceID: FileSourceID
    public let path: RemotePath

    public init(sourceID: FileSourceID, path: RemotePath) {
        self.sourceID = sourceID
        self.path = path
    }
}

public enum FileLocationResolution: Codable, Hashable, Sendable {
    case resolved(FileLocation)
    case unsupported(FileCapabilityUnsupportedReason)
}

public enum FileCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case list
    case read
    case create
    case delete
    case copy
    case move
    case tags
    case materialize
    case atomicPublish
}

public enum FileCapabilityUnsupportedReason: Error, Codable, Hashable, Sendable {
    case operationUnsupported(sourceID: FileSourceID, capability: FileCapability)
    case unknownSource(connectorID: RemoteConnectorID)
    case legacyRclone(remoteID: UUID)
    case crossSource
    case remoteOverwrite
    case listingMetadataDenied
    case itemMetadataDenied
}

extension FileCapabilityUnsupportedReason: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .operationUnsupported(let sourceID, let capability):
            "\(capability.rawValue) is unsupported for \(sourceID)"
        case .unknownSource(let connectorID):
            "Unknown file source: \(connectorID.rawValue)"
        case .legacyRclone:
            "rclone locations are not supported"
        case .crossSource:
            "Server-side copy and move require the same source account"
        case .remoteOverwrite:
            "Remote overwrite is not supported"
        case .listingMetadataDenied:
            "The directory listing reports that this operation is unavailable"
        case .itemMetadataDenied:
            "The listed item reports that this operation is unavailable"
        }
    }
}

public enum FileCapabilitySupport: Codable, Hashable, Sendable {
    case supported
    case unsupported(FileCapabilityUnsupportedReason)

    public var isSupported: Bool {
        self == .supported
    }

    public var unsupportedReason: FileCapabilityUnsupportedReason? {
        if case .unsupported(let reason) = self { reason } else { nil }
    }
}

public struct FileSourceCapabilities: Codable, Hashable, Sendable {
    public let sourceID: FileSourceID

    public init(sourceID: FileSourceID) {
        self.sourceID = sourceID
    }

    public subscript(capability: FileCapability) -> FileCapabilitySupport {
        switch sourceID {
        case .local:
            return .supported
        case .remote(_, let connectorID):
            let supported: Set<FileCapability>
            switch connectorID {
            case .webDAV:
                supported = [.list, .read, .create, .delete, .copy, .move, .materialize]
            case .kodbox:
                supported = [.list, .read, .create, .delete, .copy, .move, .tags, .materialize]
            default:
                return .unsupported(.unknownSource(connectorID: connectorID))
            }
            return supported.contains(capability)
                ? .supported
                : .unsupported(.operationUnsupported(sourceID: sourceID, capability: capability))
        }
    }
}

public struct FileListingCapabilities: Codable, Hashable, Sendable {
    public let source: FileSourceCapabilities
    public let isReadable: Bool
    public let isWritable: Bool
    public let supportsTags: Bool

    public init(
        source: FileSourceCapabilities,
        isReadable: Bool,
        isWritable: Bool,
        supportsTags: Bool
    ) {
        self.source = source
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.supportsTags = supportsTags
    }

    public init(sourceID: FileSourceID, metadata: RemoteDirectoryCapabilities) {
        self.init(
            source: FileSourceCapabilities(sourceID: sourceID),
            isReadable: metadata.isReadable,
            isWritable: metadata.isWritable,
            supportsTags: metadata.supportsTags
        )
    }

    public subscript(capability: FileCapability) -> FileCapabilitySupport {
        let sourceSupport = source[capability]
        guard sourceSupport.isSupported else { return sourceSupport }

        switch capability {
        case .list, .read, .materialize:
            return isReadable ? .supported : .unsupported(.listingMetadataDenied)
        case .create, .delete, .copy, .move, .atomicPublish:
            return isWritable ? .supported : .unsupported(.listingMetadataDenied)
        case .tags:
            return isWritable && supportsTags
                ? .supported
                : .unsupported(.listingMetadataDenied)
        }
    }
}

public struct FileItemCapabilities: Codable, Hashable, Sendable {
    public let source: FileSourceCapabilities
    public let isReadable: Bool
    public let isWritable: Bool
    public let supportsTagEditing: Bool

    public init(
        source: FileSourceCapabilities,
        isReadable: Bool,
        isWritable: Bool,
        supportsTagEditing: Bool
    ) {
        self.source = source
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.supportsTagEditing = supportsTagEditing
    }

    public init(sourceID: FileSourceID, metadata: RemoteItem) {
        self.init(
            source: FileSourceCapabilities(sourceID: sourceID),
            isReadable: metadata.isReadable,
            isWritable: metadata.isWritable,
            supportsTagEditing: metadata.supportsTagEditing
        )
    }

    public init(sourceID: FileSourceID, metadata: FileItem) {
        self.init(
            source: FileSourceCapabilities(sourceID: sourceID),
            isReadable: metadata.isReadable,
            isWritable: metadata.isWritable,
            supportsTagEditing: metadata.supportsTagEditing
        )
    }

    public subscript(capability: FileCapability) -> FileCapabilitySupport {
        let sourceSupport = source[capability]
        guard sourceSupport.isSupported else { return sourceSupport }

        switch capability {
        case .list, .create, .atomicPublish:
            return sourceSupport
        case .read, .copy, .materialize:
            return isReadable ? .supported : .unsupported(.itemMetadataDenied)
        case .delete, .move:
            return isWritable ? .supported : .unsupported(.itemMetadataDenied)
        case .tags:
            return isWritable && supportsTagEditing
                ? .supported
                : .unsupported(.itemMetadataDenied)
        }
    }
}

public struct FileRelationalCapabilities: Codable, Hashable, Sendable {
    public let source: FileSourceID
    public let destination: FileSourceID
    public let copy: FileCapabilitySupport
    public let move: FileCapabilitySupport

    public init(source: FileSourceID, destination: FileSourceID, overwriteExisting: Bool = false) {
        self.source = source
        self.destination = destination
        copy = Self.resolve(
            .copy,
            source: source,
            destination: destination,
            overwriteExisting: overwriteExisting
        )
        move = Self.resolve(
            .move,
            source: source,
            destination: destination,
            overwriteExisting: overwriteExisting
        )
    }

    public subscript(capability: FileCapability) -> FileCapabilitySupport? {
        switch capability {
        case .copy:
            copy
        case .move:
            move
        case .list, .read, .create, .delete, .tags, .materialize, .atomicPublish:
            nil
        }
    }

    private static func resolve(
        _ capability: FileCapability,
        source: FileSourceID,
        destination: FileSourceID,
        overwriteExisting: Bool
    ) -> FileCapabilitySupport {
        let sourceSupport = FileSourceCapabilities(sourceID: source)[capability]
        guard sourceSupport.isSupported else { return sourceSupport }
        let destinationSupport = FileSourceCapabilities(sourceID: destination)[.create]
        guard destinationSupport.isSupported else { return destinationSupport }
        guard source == destination else { return .unsupported(.crossSource) }
        if overwriteExisting, destination.isRemote {
            return .unsupported(.remoteOverwrite)
        }
        return .supported
    }
}
