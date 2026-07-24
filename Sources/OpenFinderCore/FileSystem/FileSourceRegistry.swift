import Foundation

public struct LocalFileSourceAdapter: Sendable {
    public let provider: LocalFileProvider

    public init(provider: LocalFileProvider) {
        self.provider = provider
    }

    public var sourceID: FileSourceID { .local }
}

public struct RemoteFileSourceAdapter: Sendable {
    public let sourceID: FileSourceID
    public let revision: String
    public let provider: any RemoteProvider

    public init(
        sourceID: FileSourceID,
        revision: String,
        provider: any RemoteProvider
    ) {
        self.sourceID = sourceID
        self.revision = revision
        self.provider = provider
    }
}

public enum FileSourceAdapter: Sendable {
    case local(LocalFileSourceAdapter)
    case remote(RemoteFileSourceAdapter)

    public var sourceID: FileSourceID {
        switch self {
        case .local(let adapter):
            adapter.sourceID
        case .remote(let adapter):
            adapter.sourceID
        }
    }

    public var isLocal: Bool {
        if case .local = self { true } else { false }
    }

    public func isRemote(connectorID: RemoteConnectorID) -> Bool {
        guard case .remote(let adapter) = self,
              case .remote(_, let resolvedConnectorID) = adapter.sourceID
        else {
            return false
        }
        return resolvedConnectorID == connectorID
    }

}

public struct ResolvedFileSource: Sendable {
    public let location: FileLocation
    public let adapter: FileSourceAdapter
    public let capabilities: FileSourceCapabilities

    public init(location: FileLocation, adapter: FileSourceAdapter) {
        self.location = location
        self.adapter = adapter
        capabilities = FileSourceCapabilities(sourceID: location.sourceID)
    }

    public func effectiveCapabilities(
        for metadata: RemoteDirectoryCapabilities
    ) -> FileListingCapabilities {
        FileListingCapabilities(sourceID: location.sourceID, metadata: metadata)
    }

    public func effectiveCapabilities(for metadata: RemoteItem) -> FileItemCapabilities {
        FileItemCapabilities(sourceID: location.sourceID, metadata: metadata)
    }

    public func effectiveCapabilities(for metadata: FileItem) -> FileItemCapabilities {
        FileItemCapabilities(sourceID: location.sourceID, metadata: metadata)
    }
}

public final class MaterializationLease: @unchecked Sendable {
    public let url: URL
    public let ownedNamespaceURL: URL?

    private let lock = NSLock()
    private var released = false

    init(url: URL, ownedNamespaceURL: URL?) {
        self.url = url
        self.ownedNamespaceURL = ownedNamespaceURL
    }

    public var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    public func release() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        if let ownedNamespaceURL,
           FileManager.default.fileExists(atPath: ownedNamespaceURL.path) {
            try FileManager.default.removeItem(at: ownedNamespaceURL)
        }
        released = true
    }

    deinit {
        try? release()
    }
}

public actor FileSourceRegistry {
    private let localAdapter: LocalFileSourceAdapter
    private let remoteProviderRegistry: RemoteProviderRegistry
    private let materializationRoot: URL

    public init(
        localProvider: LocalFileProvider = LocalFileProvider(),
        remoteProviderRegistry: RemoteProviderRegistry,
        materializationRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderMaterializations", isDirectory: true)
    ) {
        localAdapter = LocalFileSourceAdapter(provider: localProvider)
        self.remoteProviderRegistry = remoteProviderRegistry
        self.materializationRoot = materializationRoot
    }

    public func resolve(
        _ location: Location,
        revision: String = "0"
    ) async throws -> ResolvedFileSource {
        let normalized: FileLocation
        switch location.fileLocation {
        case .resolved(let location):
            normalized = location
        case .unsupported(let reason):
            throw reason
        }

        switch normalized.sourceID {
        case .local:
            return ResolvedFileSource(
                location: normalized,
                adapter: .local(localAdapter)
            )
        case .remote(let accountID, let connectorID):
            guard connectorID == .webDAV || connectorID == .kodbox else {
                throw FileCapabilityUnsupportedReason.unknownSource(
                    connectorID: connectorID
                )
            }
            let provider = try await remoteProviderRegistry.resolve(
                accountID: accountID.uuidString,
                revision: revision
            )
            return ResolvedFileSource(
                location: normalized,
                adapter: .remote(RemoteFileSourceAdapter(
                    sourceID: normalized.sourceID,
                    revision: revision,
                    provider: provider
                ))
            )
        }
    }

    public func invalidate(accountID: UUID, revision: String) async {
        await remoteProviderRegistry.invalidate(
            accountID: accountID.uuidString,
            revision: revision
        )
    }

    public func invalidate(accountID: UUID) async {
        await remoteProviderRegistry.invalidate(accountID: accountID.uuidString)
    }

    public func materialize(
        _ location: Location,
        revision: String = "0"
    ) async throws -> MaterializationLease {
        let resolved = try await resolve(location, revision: revision)
        guard resolved.capabilities[.materialize].isSupported else {
            throw resolved.capabilities[.materialize].unsupportedReason
                ?? FileCapabilityUnsupportedReason.operationUnsupported(
                    sourceID: resolved.location.sourceID,
                    capability: .materialize
                )
        }

        switch resolved.adapter {
        case .local:
            return MaterializationLease(
                url: URL(fileURLWithPath: resolved.location.path.identifier),
                ownedNamespaceURL: nil
            )
        case .remote(let adapter):
            let fileName = try safeMaterializedFileName(
                resolved.location.path.displayPath
            )
            try FileManager.default.createDirectory(
                at: materializationRoot,
                withIntermediateDirectories: true
            )
            let namespace = materializationRoot
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: namespace,
                withIntermediateDirectories: false
            )
            let destination = namespace.appendingPathComponent(
                fileName,
                isDirectory: false
            )
            do {
                _ = try await adapter.provider.download(
                    item: resolved.location.path,
                    to: destination
                )
                try Task.checkCancellation()
                return MaterializationLease(
                    url: destination,
                    ownedNamespaceURL: namespace
                )
            } catch {
                try? FileManager.default.removeItem(at: namespace)
                throw error
            }
        }
    }

    private func safeMaterializedFileName(_ displayPath: String) throws -> String {
        let name = URL(fileURLWithPath: displayPath).lastPathComponent
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("\\")
        else {
            throw OpenFinderError.operationFailed(
                "Remote file has an unsafe materialization name"
            )
        }
        return name
    }
}
