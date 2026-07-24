import CryptoKit
import Foundation

extension PersistenceMaintenance {
    func inspectArtifacts(
        _ artifacts: [UUID: ArtifactSnapshot]
    ) -> (healthyIDs: Set<UUID>, issues: [PersistenceReconciliationIssue]) {
        var healthyIDs: Set<UUID> = []
        var issues: [PersistenceReconciliationIssue] = []
        for artifact in artifacts.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            do {
                guard let rootHandle else { throw PersistenceMaintenanceError.rootUnavailable }
                let data = try rootHandle.read(relativePath: artifact.relativePath)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard data.count == artifact.byteCount, digest == artifact.sha256 else {
                    throw PersistenceMaintenanceError.digestMismatch
                }
                healthyIDs.insert(artifact.id)
            } catch let error as POSIXError where error.code == .ENOENT {
                issues.append(.init(
                    kind: .missingArtifactFile,
                    artifactID: artifact.id,
                    path: logicalURL(relativePath: artifact.relativePath).path,
                    detail: "Artifact metadata references a missing file."
                ))
            } catch {
                issues.append(.init(
                    kind: .corruptArtifactFile,
                    artifactID: artifact.id,
                    path: artifact.relativePath,
                    detail: "Artifact verification failed: \(error)"
                ))
            }
        }
        return (healthyIDs, issues)
    }

    func missingMediaIssues(
        documents: [UUID: MediaDocumentSnapshot],
        artifacts: [UUID: ArtifactSnapshot],
        healthyArtifactIDs: Set<UUID>
    ) -> [PersistenceReconciliationIssue] {
        documents.values.flatMap { document in
            document.artifactIDs.compactMap { artifactID in
                guard artifacts[artifactID] == nil || !healthyArtifactIDs.contains(artifactID) else {
                    return nil
                }
                return .init(
                    kind: .missingMediaAsset,
                    artifactID: artifactID,
                    taskID: document.taskID,
                    documentID: document.id,
                    detail: "Media document references an unavailable artifact."
                )
            }
        }
    }

    func persistArtifactDiagnostics(
        _ issues: [PersistenceReconciliationIssue],
        now: Date
    ) async {
        for issue in issues where issue.artifactID != nil {
            do {
                try await databasePool.write { db in
                    try db.execute(
                        sql: """
                            UPDATE artifact_records
                            SET reconciliation_reason = ?, reconciled_at = ?,
                                cleanup_attempts = cleanup_attempts + 1
                            WHERE artifact_id = ?
                            """,
                        arguments: [
                            issue.detail,
                            now.timeIntervalSince1970,
                            issue.artifactID?.uuidString
                        ]
                    )
                }
            } catch {
                continue
            }
        }
    }

    func removeLinks(taskID: UUID) async throws {
        try await databasePool.write { db in
            try db.execute(
                sql: "DELETE FROM task_artifacts WHERE task_id = ?",
                arguments: [taskID.uuidString]
            )
        }
    }

    func removeArtifactRowThenFile(_ artifact: ArtifactSnapshot) async throws {
        guard let rootHandle else { throw PersistenceMaintenanceError.rootUnavailable }
        try rootHandle.verifyPath(artifactRoot)
        let removal = ArtifactFileRemoval(
            rootHandle: rootHandle,
            logicalRoot: artifactRoot,
            relativePath: artifact.relativePath,
            gate: fileManager as? PersistenceArtifactRemovalGate
        )
        try await databasePool.write { db in
            try db.execute(
                sql: "DELETE FROM artifact_records WHERE artifact_id = ?",
                arguments: [artifact.id.uuidString]
            )
            try removal.perform()
        }
    }

    func removeTaskRecord(_ id: UUID) async throws {
        try await databasePool.write { db in
            try db.execute(
                sql: "DELETE FROM task_records WHERE task_id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    func removeOrphanedStaging(
        knownArtifactIDs: Set<UUID>
    ) -> (paths: [String], issues: [PersistenceReconciliationIssue]) {
        let entries: [PersistenceRootEntry]
        do {
            guard let rootHandle else { throw PersistenceMaintenanceError.rootUnavailable }
            entries = try rootHandle.entries(relativeDirectory: ".staging")
            try rootHandle.verifyPath(artifactRoot)
        } catch let error as POSIXError where error.code == .ENOENT {
            do {
                guard let rootHandle else { throw PersistenceMaintenanceError.rootUnavailable }
                try rootHandle.verifyPath(artifactRoot)
            } catch {
                return ([], [cleanupIssue(path: artifactRoot.path, error: error)])
            }
            return ([], [])
        } catch {
            return ([], [cleanupIssue(path: artifactRoot.path, error: error)])
        }
        let payloads = entries.filter {
            $0.isRegularFile && NSString(string: $0.relativePath).lastPathComponent == "payload"
        }
        var paths: [String] = []
        var issues: [PersistenceReconciliationIssue] = []
        for payload in payloads {
            let artifactDirectory = NSString(string: payload.relativePath).deletingLastPathComponent
            let payloadURL = logicalURL(relativePath: payload.relativePath)
            guard let artifactID = UUID(uuidString: NSString(string: artifactDirectory).lastPathComponent) else {
                issues.append(.init(
                    kind: .corruptArtifactRow,
                    path: payloadURL.path,
                    detail: "Staging artifact directory has an invalid UUID."
                ))
                continue
            }
            guard !knownArtifactIDs.contains(artifactID) else { continue }
            do {
                guard let rootHandle else { throw PersistenceMaintenanceError.rootUnavailable }
                try rootHandle.verifyPath(artifactRoot)
                try rootHandle.removeTree(relativePath: artifactDirectory)
                try rootHandle.verifyPath(artifactRoot)
                paths.append(payloadURL.path)
            } catch {
                issues.append(cleanupIssue(
                    artifactID: artifactID,
                    path: payloadURL.path,
                    error: error
                ))
            }
        }
        return (paths, issues)
    }

    func removeOrphanedPublished(
        knownArtifactIDs: Set<UUID>,
        knownRelativePaths: Set<String>
    ) -> (artifactIDs: [UUID], issues: [PersistenceReconciliationIssue]) {
        let files: [PersistenceRootEntry]
        do {
            guard let rootHandle else { throw PersistenceMaintenanceError.rootUnavailable }
            files = try rootHandle.entries(relativeDirectory: "published")
            try rootHandle.verifyPath(artifactRoot)
        } catch let error as POSIXError where error.code == .ENOENT {
            do {
                guard let rootHandle else { throw PersistenceMaintenanceError.rootUnavailable }
                try rootHandle.verifyPath(artifactRoot)
            } catch {
                return ([], [cleanupIssue(path: artifactRoot.path, error: error)])
            }
            return ([], [])
        } catch {
            return ([], [cleanupIssue(path: artifactRoot.path, error: error)])
        }
        var artifactIDs: [UUID] = []
        var issues: [PersistenceReconciliationIssue] = []
        for file in files {
            guard !file.isDirectory else { continue }
            let fileURL = logicalURL(relativePath: file.relativePath)
            guard file.isRegularFile, !file.isSymbolicLink else {
                issues.append(.init(
                    kind: .corruptArtifactRow,
                    path: fileURL.path,
                    detail: "Published artifact is not a confined regular file."
                ))
                continue
            }
            let artifactDirectory = NSString(string: file.relativePath).deletingLastPathComponent
            guard let artifactID = UUID(uuidString: NSString(string: artifactDirectory).lastPathComponent) else {
                issues.append(.init(
                    kind: .corruptArtifactRow,
                    path: fileURL.path,
                    detail: "Published artifact directory has an invalid UUID."
                ))
                continue
            }
            guard !knownArtifactIDs.contains(artifactID),
                  !knownRelativePaths.contains(file.relativePath) else { continue }
            do {
                guard let rootHandle else { throw PersistenceMaintenanceError.rootUnavailable }
                try rootHandle.verifyPath(artifactRoot)
                try rootHandle.removeTree(relativePath: artifactDirectory)
                try rootHandle.verifyPath(artifactRoot)
                artifactIDs.append(artifactID)
            } catch {
                issues.append(cleanupIssue(
                    artifactID: artifactID,
                    path: fileURL.path,
                    error: error
                ))
            }
        }
        return (artifactIDs, issues)
    }

    private func logicalURL(relativePath: String) -> URL {
        artifactRoot.appendingPathComponent(relativePath).standardizedFileURL
    }
}

private enum PersistenceMaintenanceError: Error {
    case digestMismatch, rootUnavailable
}

protocol PersistenceArtifactRemovalGate {
    func beforeArtifactRemoval(at url: URL) throws
}

private struct ArtifactFileRemoval: @unchecked Sendable {
    let rootHandle: PersistenceRootHandle
    let logicalRoot: URL
    let relativePath: String
    let gate: PersistenceArtifactRemovalGate?

    func perform() throws {
        let url = logicalRoot.appendingPathComponent(relativePath)
        try gate?.beforeArtifactRemoval(at: url)
        try rootHandle.verifyPath(logicalRoot)
        try rootHandle.removeFileAndEmptyParent(relativePath: relativePath)
        try rootHandle.verifyPath(logicalRoot)
    }
}
