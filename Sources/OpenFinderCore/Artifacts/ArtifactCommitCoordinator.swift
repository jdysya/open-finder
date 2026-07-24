import Foundation

public actor ArtifactCommitCoordinator {
    public typealias CommitEffects = @Sendable () async throws -> Void
    public typealias CleanupWorkspace = @Sendable () async throws -> Void

    private let store: ArtifactStore
    private let metadata: any ArtifactMetadataBackend

    public init(store: ArtifactStore, metadata: any ArtifactMetadataBackend) {
        self.store = store
        self.metadata = metadata
    }

    public func commit(
        taskID: UUID,
        schemaID: String,
        artifacts: [PluginFileArtifact],
        from reader: ConfinedArtifactReader,
        markEffectsCommitted: CommitEffects,
        cleanupWorkspace: CleanupWorkspace
    ) async throws -> [ArtifactRecord] {
        try Task.checkCancellation()
        var records: [ArtifactRecord] = []
        var effectsCommitted = false
        do {
            for artifact in artifacts {
                try Task.checkCancellation()
                var record = try await store.stage(
                    taskID: taskID,
                    schemaID: schemaID,
                    artifact: artifact,
                    from: reader
                )
                records.append(record)
                try Task.checkCancellation()
                record = try await store.publish(record, taskID: taskID)
                records[records.count - 1] = record
                try Task.checkCancellation()
                record = try await store.link(record, taskID: taskID)
                records[records.count - 1] = record
            }

            try Task.checkCancellation()
            try await markEffectsCommitted()
            effectsCommitted = true
            try await metadata.markTaskEffectsCommitted(taskID)
            for index in records.indices {
                records[index] = try await store.markCommitted(records[index], taskID: taskID)
            }
        } catch {
            if !effectsCommitted {
                await store.rollback(records, taskID: taskID)
            }
            throw error
        }

        do {
            try await cleanupWorkspace()
            await metadata.clearCleanupFailure(taskID: taskID)
        } catch {
            await metadata.recordCleanupFailure(taskID: taskID, message: String(describing: error))
        }
        return records
    }

    public func reconcileAtStartup() async -> ArtifactReconciliationReport {
        await store.reconcile()
    }
}
