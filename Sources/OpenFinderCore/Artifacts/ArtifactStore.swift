import CryptoKit
import Darwin
import Foundation

public enum ArtifactStoreError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidState(ArtifactLifecycleState)
    case duplicateArtifactID(UUID)
    case metadataRecordMissing(UUID)
    case fileOperationFailed
}

public enum ArtifactReconciliationIssueKind: String, Sendable, Hashable {
    case missingFile
    case corruptFile
    case orphanedPublishedFile
    case cleanupFailure
}

public struct ArtifactReconciliationIssue: Sendable, Hashable {
    public let artifactID: UUID?
    public let taskID: UUID?
    public let kind: ArtifactReconciliationIssueKind
    public let path: String
    public let detail: String

    public init(
        artifactID: UUID?,
        taskID: UUID?,
        kind: ArtifactReconciliationIssueKind,
        path: String,
        detail: String
    ) {
        self.artifactID = artifactID
        self.taskID = taskID
        self.kind = kind
        self.path = path
        self.detail = detail
    }
}

public struct ArtifactReconciliationReport: Sendable, Hashable {
    public let issues: [ArtifactReconciliationIssue]
    public let repairedArtifactIDs: [UUID]
    public let removedOrphanedStagingPaths: [String]

    public init(
        issues: [ArtifactReconciliationIssue],
        repairedArtifactIDs: [UUID],
        removedOrphanedStagingPaths: [String]
    ) {
        self.issues = issues
        self.repairedArtifactIDs = repairedArtifactIDs
        self.removedOrphanedStagingPaths = removedOrphanedStagingPaths
    }
}

public actor ArtifactStore {
    public let root: URL
    private let metadata: any ArtifactMetadataBackend
    private let fileManager: FileManager
    private let rootDevice: dev_t
    private let rootInode: ino_t

    public init(
        root: URL,
        metadata: any ArtifactMetadataBackend,
        fileManager: FileManager = .default
    ) throws {
        self.root = root.standardizedFileURL
        self.metadata = metadata
        self.fileManager = fileManager
        do {
            try fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: self.root.appendingPathComponent(".staging", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: self.root.appendingPathComponent("published", isDirectory: true),
                withIntermediateDirectories: true
            )
            let descriptor = Darwin.open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ArtifactStoreError.invalidRoot }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
                throw ArtifactStoreError.invalidRoot
            }
            rootDevice = status.st_dev
            rootInode = status.st_ino
        } catch {
            throw ArtifactStoreError.invalidRoot
        }
    }

    public func stagingURL(taskID: UUID, artifactID: UUID) -> URL {
        root.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
            .appendingPathComponent(artifactID.uuidString, isDirectory: true)
            .appendingPathComponent("payload")
    }

    nonisolated static func publishedRelativePath(
        taskID: UUID,
        artifact: PluginFileArtifact
    ) -> String {
        let filename = URL(fileURLWithPath: artifact.relativePath).lastPathComponent
        return "published/\(taskID.uuidString)/\(artifact.artifactID.uuidString)/\(filename)"
    }

    public func stage(
        taskID: UUID,
        schemaID: String,
        artifact: PluginFileArtifact,
        from reader: ConfinedArtifactReader,
        dataOverride: Data? = nil,
        at date: Date = .now
    ) async throws -> ArtifactRecord {
        try verifyRoot()
        try Task.checkCancellation()
        let id = artifact.artifactID
        guard await metadata.record(id: id) == nil else {
            throw ArtifactStoreError.duplicateArtifactID(id)
        }
        let staging = stagingURL(taskID: taskID, artifactID: id)
        try fileManager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if let dataOverride {
                guard dataOverride.count == artifact.byteCount else {
                    throw ConfinedArtifactError.sizeMismatch
                }
                let digest = SHA256.hash(data: dataOverride)
                    .map { String(format: "%02x", $0) }
                    .joined()
                guard digest == artifact.sha256 else {
                    throw ConfinedArtifactError.hashMismatch
                }
                try dataOverride.write(to: staging, options: .atomic)
            } else {
                try reader.copy(artifact: artifact, to: staging)
            }
            try syncDirectory(staging.deletingLastPathComponent())
            try Task.checkCancellation()

            let staged = ArtifactRecord(
                id: id,
                schemaID: schemaID,
                relativePath: Self.publishedRelativePath(taskID: taskID, artifact: artifact),
                mediaType: artifact.mediaType,
                byteCount: artifact.byteCount,
                sha256: artifact.sha256,
                state: .staging,
                stagedAt: date
            )
            let validated = try staged.transition(to: .validated, at: date)
            try await metadata.upsert(validated, taskID: taskID)
            return validated
        } catch {
            try? fileManager.removeItem(at: staging.deletingLastPathComponent())
            try? fileManager.removeItem(at: staging.deletingLastPathComponent().deletingLastPathComponent())
            throw error
        }
    }

    public func publish(_ record: ArtifactRecord, taskID: UUID) async throws -> ArtifactRecord {
        try verifyRoot()
        guard record.state == .validated else { throw ArtifactStoreError.invalidState(record.state) }
        let staging = stagingURL(taskID: taskID, artifactID: record.id)
        let destination = root.appendingPathComponent(record.relativePath)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard Darwin.rename(staging.path, destination.path) == 0 else {
            throw ArtifactStoreError.fileOperationFailed
        }
        try syncDirectory(destination.deletingLastPathComponent())
        try? fileManager.removeItem(at: staging.deletingLastPathComponent())
        try? fileManager.removeItem(at: staging.deletingLastPathComponent().deletingLastPathComponent())
        let published = try record.transition(to: .filePublished)
        try await metadata.upsert(published, taskID: taskID)
        return published
    }

    public func link(_ record: ArtifactRecord, taskID: UUID) async throws -> ArtifactRecord {
        guard record.state == .filePublished else { throw ArtifactStoreError.invalidState(record.state) }
        try await metadata.link(record.id, to: taskID)
        let linked = try record.transition(to: .rowLinked)
        try await metadata.upsert(linked, taskID: taskID)
        return linked
    }

    public func markCommitted(_ record: ArtifactRecord, taskID: UUID, at date: Date = .now) async throws -> ArtifactRecord {
        guard record.state == .rowLinked else { throw ArtifactStoreError.invalidState(record.state) }
        let committed = try record.transition(to: .committed, at: date)
        try await metadata.upsert(committed, taskID: taskID)
        return committed
    }

    public func read(_ record: ArtifactRecord) throws -> Data {
        try verifyRoot()
        return try ConfinedArtifactReader(root: root).read(.init(
            artifactID: record.id,
            relativePath: record.relativePath,
            mediaType: record.mediaType,
            byteCount: record.byteCount,
            sha256: record.sha256
        ))
    }

    public func rollback(_ records: [ArtifactRecord], taskID: UUID) async {
        guard (try? verifyRoot()) != nil else { return }
        for record in records {
            let staging = stagingURL(taskID: taskID, artifactID: record.id)
            try? fileManager.removeItem(at: staging.deletingLastPathComponent())
            try? fileManager.removeItem(at: root.appendingPathComponent(record.relativePath).deletingLastPathComponent())
            if let cleaned = try? record.cancelling() {
                try? await metadata.upsert(cleaned, taskID: taskID)
            }
        }
        try? fileManager.removeItem(
            at: root.appendingPathComponent(".staging", isDirectory: true)
                .appendingPathComponent(taskID.uuidString, isDirectory: true)
        )
    }

    public func reconcile() async -> ArtifactReconciliationReport {
        do {
            try verifyRoot()
        } catch {
            return .init(
                issues: [.init(
                    artifactID: nil, taskID: nil, kind: .cleanupFailure,
                    path: root.path, detail: "Artifact root was replaced."
                )],
                repairedArtifactIDs: [],
                removedOrphanedStagingPaths: []
            )
        }
        var issues: [ArtifactReconciliationIssue] = []
        var repaired: [UUID] = []
        var removedStaging: [String] = []
        let entries = await metadata.entries()
        let knownIDs = Set(entries.map(\.record.id))

        for path in leafPayloads(under: root.appendingPathComponent(".staging", isDirectory: true)) {
            let components = path.pathComponents
            guard components.count >= 2,
                  let id = UUID(uuidString: components[components.count - 2]),
                  !knownIDs.contains(id) else { continue }
            do {
                try fileManager.removeItem(at: path.deletingLastPathComponent())
                try? fileManager.removeItem(at: path.deletingLastPathComponent().deletingLastPathComponent())
                removedStaging.append(path.path)
            } catch {
                issues.append(.init(
                    artifactID: id, taskID: nil, kind: .cleanupFailure,
                    path: path.path, detail: String(describing: error)
                ))
            }
        }

        let knownPublishedPaths = Set(entries.map { root.appendingPathComponent($0.record.relativePath).standardizedFileURL.path })
        let publishedRoot = root.appendingPathComponent("published", isDirectory: true)
        for path in leafFiles(under: publishedRoot)
            where !knownPublishedPaths.contains(path.standardizedFileURL.path) {
            issues.append(.init(
                artifactID: nil, taskID: nil, kind: .orphanedPublishedFile,
                path: diagnosticPath(path, relativeTo: publishedRoot),
                detail: "Published file has no metadata row."
            ))
        }

        for entry in entries {
            var record = entry.record
            let taskID = entry.taskID
            do {
                switch record.state {
                case .staging, .validated:
                    let staging = stagingURL(taskID: taskID, artifactID: record.id)
                    guard fileManager.fileExists(atPath: staging.path) else {
                        issues.append(missingIssue(record, taskID: taskID, path: staging.path))
                        continue
                    }
                    if record.state == .staging {
                        record = try record.transition(to: .validated)
                        try await metadata.upsert(record, taskID: taskID)
                    }
                    record = try await publish(record, taskID: taskID)
                    record = try await link(record, taskID: taskID)
                    repaired.append(record.id)
                case .filePublished:
                    guard try verify(record, issues: &issues, taskID: taskID) else { continue }
                    record = try await link(record, taskID: taskID)
                    repaired.append(record.id)
                    if await metadata.taskEffectsCommitted(taskID) {
                        _ = try await markCommitted(record, taskID: taskID)
                    }
                case .rowLinked:
                    guard try verify(record, issues: &issues, taskID: taskID) else { continue }
                    if !(await metadata.isLinked(record.id, to: taskID)) {
                        try await metadata.link(record.id, to: taskID)
                        repaired.append(record.id)
                    }
                    if await metadata.taskEffectsCommitted(taskID) {
                        _ = try await markCommitted(record, taskID: taskID)
                        repaired.append(record.id)
                    }
                case .committed:
                    _ = try verify(record, issues: &issues, taskID: taskID)
                    if !(await metadata.isLinked(record.id, to: taskID)) {
                        try await metadata.link(record.id, to: taskID)
                        repaired.append(record.id)
                    }
                case .cleaned:
                    let published = root.appendingPathComponent(record.relativePath).deletingLastPathComponent()
                    if fileManager.fileExists(atPath: published.path) {
                        try fileManager.removeItem(at: published)
                        repaired.append(record.id)
                    }
                }
            } catch {
                issues.append(.init(
                    artifactID: record.id, taskID: taskID, kind: .cleanupFailure,
                    path: root.appendingPathComponent(record.relativePath).path,
                    detail: String(describing: error)
                ))
            }
        }

        for taskID in Set(entries.map(\.taskID)) {
            if let failure = await metadata.cleanupFailure(taskID: taskID) {
                issues.append(.init(
                    artifactID: nil, taskID: taskID, kind: .cleanupFailure,
                    path: "", detail: failure
                ))
            }
        }
        return .init(
            issues: issues.sorted { ($0.path, $0.kind.rawValue) < ($1.path, $1.kind.rawValue) },
            repairedArtifactIDs: Array(Set(repaired)).sorted { $0.uuidString < $1.uuidString },
            removedOrphanedStagingPaths: removedStaging.sorted()
        )
    }

    private func verify(
        _ record: ArtifactRecord,
        issues: inout [ArtifactReconciliationIssue],
        taskID: UUID
    ) throws -> Bool {
        let path = root.appendingPathComponent(record.relativePath).path
        guard fileManager.fileExists(atPath: path) else {
            issues.append(missingIssue(record, taskID: taskID, path: path))
            return false
        }
        do {
            _ = try read(record)
            return true
        } catch {
            issues.append(.init(
                artifactID: record.id, taskID: taskID, kind: .corruptFile,
                path: path, detail: String(describing: error)
            ))
            return false
        }
    }

    private func missingIssue(_ record: ArtifactRecord, taskID: UUID, path: String) -> ArtifactReconciliationIssue {
        .init(
            artifactID: record.id, taskID: taskID, kind: .missingFile,
            path: path, detail: "Metadata row references a missing artifact file."
        )
    }

    private func leafPayloads(under directory: URL) -> [URL] {
        leafFiles(under: directory).filter { $0.lastPathComponent == "payload" }
    }

    private func leafFiles(under directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            return url
        }
    }

    private func diagnosticPath(_ path: URL, relativeTo directory: URL) -> String {
        let canonicalDirectory = directory.resolvingSymlinksInPath().path
        let canonicalPath = path.resolvingSymlinksInPath().path
        let prefix = canonicalDirectory.hasSuffix("/") ? canonicalDirectory : canonicalDirectory + "/"
        guard canonicalPath.hasPrefix(prefix) else { return path.path }
        return directory.appendingPathComponent(String(canonicalPath.dropFirst(prefix.count))).path
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ArtifactStoreError.fileOperationFailed }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw ArtifactStoreError.fileOperationFailed }
    }

    private func verifyRoot() throws {
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ArtifactStoreError.invalidRoot }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_dev == rootDevice,
              status.st_ino == rootInode else {
            throw ArtifactStoreError.invalidRoot
        }
    }
}
