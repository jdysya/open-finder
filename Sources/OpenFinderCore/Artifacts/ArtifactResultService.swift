import CryptoKit
import Foundation

public enum ArtifactResultServiceError: Error, Equatable, Sendable {
    case artifactNotFound(UUID)
    case artifactNotCommitted(UUID)
    case mediaDocumentPersistenceDeferred(UUID)
    case mediaDocumentRecoverySourceMissing(UUID)
}

public protocol MediaAnalysisDocumentStore: Sendable {
    func persist(
        _ document: MediaAnalysisDocument,
        payload: Data,
        committedArtifacts: [ArtifactRecord]
    ) async throws
}

private struct PreparedArtifactResultContext {
    let context: PluginResultHandlingContext
    let artifactDataOverrides: [UUID: Data]
    let mediaDocument: MediaAnalysisDocument?
}

public actor ArtifactResultService {
    private let store: ArtifactStore
    private let metadata: any ArtifactMetadataBackend
    private let commitCoordinator: ArtifactCommitCoordinator
    private let mediaDocuments: (any MediaAnalysisDocumentStore)?

    public init(
        store: ArtifactStore,
        metadata: any ArtifactMetadataBackend,
        mediaDocuments: (any MediaAnalysisDocumentStore)? = nil
    ) {
        self.store = store
        self.metadata = metadata
        self.mediaDocuments = mediaDocuments
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

    @discardableResult
    public func recoverMediaAnalysisDocument(taskID: UUID) async throws -> Bool {
        guard let mediaDocuments else {
            throw ArtifactResultServiceError.mediaDocumentRecoverySourceMissing(taskID)
        }
        let records = await query(
            taskID: taskID,
            schemaID: MediaAnalysisDocument.schemaIdentifier
        )
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var recoveredDocument: MediaAnalysisDocument?
        var recoveredPayload: Data?
        for record in records where record.mediaType == "application/json" {
            guard
                let payload = try? await store.read(record),
                let document = try? JSONDecoder.openFinder.decode(
                    MediaAnalysisDocument.self,
                    from: payload
                ),
                document.taskID == taskID,
                (try? document.validate(artifacts: recordsByID)) != nil
            else { continue }
            recoveredDocument = document
            recoveredPayload = payload
            break
        }
        guard let recoveredDocument, let recoveredPayload else {
            throw ArtifactResultServiceError.mediaDocumentRecoverySourceMissing(taskID)
        }
        do {
            try await mediaDocuments.persist(
                recoveredDocument,
                payload: recoveredPayload,
                committedArtifacts: records
            )
            await metadata.clearCleanupFailure(taskID: taskID)
            return true
        } catch {
            await metadata.recordCleanupFailure(
                taskID: taskID,
                message: "media-analysis-document-persistence-failed"
            )
            throw ArtifactResultServiceError.mediaDocumentPersistenceDeferred(taskID)
        }
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

    public func commit(
        _ context: PluginResultHandlingContext,
        workspace: PluginExecutionWorkspace,
        markEffectsCommitted: @escaping ArtifactCommitCoordinator.CommitEffects,
        cleanupWorkspace: @escaping ArtifactCommitCoordinator.CleanupWorkspace
    ) async throws -> PluginResultHandlingContext {
        try Task.checkCancellation()
        let prepared = try prepareMediaAnalysisContext(context, workspace: workspace)
        let preparedContext = prepared.context
        let fileArtifacts = preparedContext.events.flatMap { event -> [PluginFileArtifact] in
            guard case .result(_, _, _, let artifacts) = event else { return [] }
            return artifacts.compactMap(\.file)
        }
        let anticipatedRecords = fileArtifacts.map { artifact in
            ArtifactRecord(
                id: artifact.artifactID,
                schemaID: preparedContext.resultSchemaID,
                relativePath: ArtifactStore.publishedRelativePath(
                    taskID: preparedContext.taskID,
                    artifact: artifact
                ),
                mediaType: artifact.mediaType,
                byteCount: artifact.byteCount,
                sha256: artifact.sha256,
                state: .committed,
                stagedAt: .distantPast,
                finishedAt: .distantPast
            )
        }
        let mediaDocument = prepared.mediaDocument
        if let mediaDocument {
            try mediaDocument.validate(artifacts: Dictionary(
                uniqueKeysWithValues: anticipatedRecords.map { ($0.id, $0) }
            ))
        }
        let mediaDocumentPayload = try mediaDocument.map {
            try JSONEncoder.openFinder.encode($0)
        }
        guard !fileArtifacts.isEmpty else {
            if let mediaDocument, let mediaDocumentPayload, let mediaDocuments {
                try await mediaDocuments.persist(
                    mediaDocument,
                    payload: mediaDocumentPayload,
                    committedArtifacts: []
                )
            }
            try Task.checkCancellation()
            try await markEffectsCommitted()
            try await metadata.markTaskEffectsCommitted(preparedContext.taskID)
            return preparedContext
        }
        let records = try await commitCoordinator.commit(
            taskID: preparedContext.taskID,
            schemaID: preparedContext.resultSchemaID,
            artifacts: fileArtifacts,
            from: ConfinedArtifactReader(root: workspace.outputDirectory),
            artifactDataOverrides: prepared.artifactDataOverrides,
            markEffectsCommitted: markEffectsCommitted,
            cleanupWorkspace: cleanupWorkspace
        )
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let events = preparedContext.events.map { event in
            guard case .result(let status, let message, let clipboard, let artifacts) = event else {
                return event
            }
            let committedArtifacts = artifacts.map { artifact in
                guard let file = artifact.file, let record = recordsByID[file.artifactID] else {
                    return artifact
                }
                return PluginArtifact(
                    type: artifact.type,
                    file: .init(
                        artifactID: record.id,
                        relativePath: record.relativePath,
                        mediaType: record.mediaType,
                        byteCount: record.byteCount,
                        sha256: record.sha256
                    )
                )
            }
            return .result(
                status: status,
                message: message,
                clipboard: clipboard,
                artifacts: committedArtifacts
            )
        }
        let committedContext = PluginResultHandlingContext(
            resultSchemaID: preparedContext.resultSchemaID,
            pluginID: preparedContext.pluginID,
            pluginVersion: preparedContext.pluginVersion,
            actionID: preparedContext.actionID,
            taskID: preparedContext.taskID,
            events: events,
            outputDirectory: store.root
        )
        try await persistMediaAnalysisDocument(
            mediaDocument,
            payload: mediaDocumentPayload,
            committedArtifacts: records,
            taskID: preparedContext.taskID
        )
        return committedContext
    }

    private func prepareMediaAnalysisContext(
        _ context: PluginResultHandlingContext,
        workspace: PluginExecutionWorkspace
    ) throws -> PreparedArtifactResultContext {
        guard context.resultSchemaID == MediaAnalysisDocument.schemaIdentifier else {
            return PreparedArtifactResultContext(
                context: context,
                artifactDataOverrides: [:],
                mediaDocument: nil
            )
        }
        let artifacts = context.events.flatMap { event -> [PluginArtifact] in
            guard case .result(_, _, _, let artifacts) = event else { return [] }
            return artifacts
        }
        let schemaArtifacts = artifacts.filter { $0.type == context.resultSchemaID }
        guard schemaArtifacts.count == 1, let schemaArtifact = schemaArtifacts.first else {
            throw PluginResultHandlingError.missingSchemaArtifact(context.resultSchemaID)
        }
        let files = artifacts.compactMap(\.file)
        var pathsByArtifactID: [UUID: String] = [:]
        for file in files {
            guard pathsByArtifactID[file.artifactID] == nil else {
                throw ArtifactStoreError.duplicateArtifactID(file.artifactID)
            }
            pathsByArtifactID[file.artifactID] = ArtifactStore.publishedRelativePath(
                taskID: context.taskID,
                artifact: file
            )
        }

        let sourceData: Data
        switch schemaArtifact.payload {
        case .inline(let content):
            sourceData = Data(content.utf8)
        case .file(let file):
            guard file.mediaType == "application/json" else {
                throw PluginResultHandlingError.malformedSchemaArtifact(context.resultSchemaID)
            }
            do {
                sourceData = try ConfinedArtifactReader(root: workspace.outputDirectory).read(file)
            } catch {
                throw PluginResultHandlingError.malformedSchemaArtifact(context.resultSchemaID)
            }
        }
        let document: MediaAnalysisDocument
        do {
            document = try JSONDecoder.openFinder.decode(MediaAnalysisDocument.self, from: sourceData)
        } catch {
            throw PluginResultHandlingError.malformedSchemaArtifact(context.resultSchemaID)
        }
        guard document.taskID == context.taskID else {
            throw PluginResultHandlingError.taskIDMismatch(
                expected: context.taskID,
                actual: document.taskID
            )
        }
        let rewritten = try document.replacingAssetPaths(pathsByArtifactID)
        let rewrittenData = try JSONEncoder.openFinder.encode(rewritten)
        var artifactDataOverrides: [UUID: Data] = [:]

        let rewrittenEvents = try context.events.map { event -> PluginOutputEvent in
            guard case .result(let status, let message, let clipboard, let eventArtifacts) = event else {
                return event
            }
            let rewrittenArtifacts = try eventArtifacts.map { artifact -> PluginArtifact in
                guard artifact.type == context.resultSchemaID else { return artifact }
                switch artifact.payload {
                case .inline:
                    guard let content = String(data: rewrittenData, encoding: .utf8) else {
                        throw PluginResultHandlingError.malformedSchemaArtifact(context.resultSchemaID)
                    }
                    return PluginArtifact(type: artifact.type, content: content)
                case .file(let file):
                    artifactDataOverrides[file.artifactID] = rewrittenData
                    return PluginArtifact(
                        type: artifact.type,
                        file: .init(
                            artifactID: file.artifactID,
                            relativePath: file.relativePath,
                            mediaType: file.mediaType,
                            byteCount: rewrittenData.count,
                            sha256: SHA256.hash(data: rewrittenData)
                                .map { String(format: "%02x", $0) }
                                .joined()
                        )
                    )
                }
            }
            return .result(
                status: status,
                message: message,
                clipboard: clipboard,
                artifacts: rewrittenArtifacts
            )
        }
        return PreparedArtifactResultContext(
            context: PluginResultHandlingContext(
                resultSchemaID: context.resultSchemaID,
                pluginID: context.pluginID,
                pluginVersion: context.pluginVersion,
                actionID: context.actionID,
                taskID: context.taskID,
                events: rewrittenEvents,
                outputDirectory: context.outputDirectory
            ),
            artifactDataOverrides: artifactDataOverrides,
            mediaDocument: rewritten
        )
    }

    private func persistMediaAnalysisDocument(
        _ document: MediaAnalysisDocument?,
        payload: Data?,
        committedArtifacts: [ArtifactRecord],
        taskID: UUID
    ) async throws {
        guard let document, let payload, let mediaDocuments else { return }
        do {
            try await mediaDocuments.persist(
                document,
                payload: payload,
                committedArtifacts: committedArtifacts
            )
        } catch {
            await metadata.recordCleanupFailure(
                taskID: taskID,
                message: "media-analysis-document-persistence-failed"
            )
            throw ArtifactResultServiceError.mediaDocumentPersistenceDeferred(taskID)
        }
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
