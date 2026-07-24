import Foundation

public enum ArtifactResultServiceError: Error, Equatable, Sendable {
    case artifactNotFound(UUID)
    case artifactNotCommitted(UUID)
}

public actor ArtifactResultService {
    private let store: ArtifactStore
    private let metadata: any ArtifactMetadataBackend
    private let commitCoordinator: ArtifactCommitCoordinator

    public init(store: ArtifactStore, metadata: any ArtifactMetadataBackend) {
        self.store = store
        self.metadata = metadata
        commitCoordinator = ArtifactCommitCoordinator(store: store, metadata: metadata)
    }

    public func query(
        taskID: UUID? = nil,
        schemaID: String? = nil
    ) async -> [ArtifactRecord] {
        await metadata.entries()
            .filter { entry in
                entry.record.state == .committed
                    && taskID.map { $0 == entry.taskID } != false
                    && schemaID.map { $0 == entry.record.schemaID } != false
            }
            .map(\.record)
            .sorted { lhs, rhs in
                if lhs.stagedAt != rhs.stagedAt { return lhs.stagedAt < rhs.stagedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func open(_ artifactID: UUID) async throws -> Data {
        let record = try await committedRecord(id: artifactID)
        return try await store.read(record)
    }

    public func fileURL(for artifactID: UUID) async throws -> URL {
        let record = try await committedRecord(id: artifactID)
        return store.root.appendingPathComponent(record.relativePath)
    }

    @discardableResult
    public func export(_ artifactID: UUID, to destination: URL) async throws -> URL {
        let data = try await open(artifactID)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public func commit(
        taskID: UUID,
        schemaID: String,
        artifacts: [PluginFileArtifact],
        from reader: ConfinedArtifactReader,
        markEffectsCommitted: @escaping ArtifactCommitCoordinator.CommitEffects,
        cleanupWorkspace: @escaping ArtifactCommitCoordinator.CleanupWorkspace
    ) async throws -> [ArtifactRecord] {
        try await commitCoordinator.commit(
            taskID: taskID,
            schemaID: schemaID,
            artifacts: artifacts,
            from: reader,
            markEffectsCommitted: markEffectsCommitted,
            cleanupWorkspace: cleanupWorkspace
        )
    }

    private func committedRecord(id: UUID) async throws -> ArtifactRecord {
        guard let record = await metadata.record(id: id) else {
            throw ArtifactResultServiceError.artifactNotFound(id)
        }
        guard record.state == .committed else {
            throw ArtifactResultServiceError.artifactNotCommitted(id)
        }
        return record
    }
}
