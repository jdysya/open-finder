import CryptoKit
import Foundation

extension PersistenceMaintenance {
    func inspectArtifacts(
        _ artifacts: [UUID: ArtifactSnapshot]
    ) -> (healthyIDs: Set<UUID>, issues: [PersistenceReconciliationIssue]) {
        var healthyIDs: Set<UUID> = []
        var issues: [PersistenceReconciliationIssue] = []
        for artifact in artifacts.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let url = artifactRoot.appendingPathComponent(artifact.relativePath)
            guard fileManager.fileExists(atPath: url.path) else {
                issues.append(.init(
                    kind: .missingArtifactFile,
                    artifactID: artifact.id,
                    path: url.path,
                    detail: "Artifact metadata references a missing file."
                ))
                continue
            }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard data.count == artifact.byteCount, digest == artifact.sha256 else {
                    throw PersistenceMaintenanceError.digestMismatch
                }
                healthyIDs.insert(artifact.id)
            } catch {
                issues.append(.init(
                    kind: .corruptArtifactFile,
                    artifactID: artifact.id,
                    path: url.path,
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

    func removeArtifactRow(_ id: UUID) async throws {
        try await databasePool.write { db in
            try db.execute(
                sql: "DELETE FROM artifact_records WHERE artifact_id = ?",
                arguments: [id.uuidString]
            )
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

    func removeArtifactFile(_ artifact: ArtifactSnapshot) throws {
        let url = artifactRoot.appendingPathComponent(artifact.relativePath)
        try fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: url.deletingLastPathComponent())
    }

    func removeOrphanedStaging(
        knownArtifactIDs: Set<UUID>
    ) -> (paths: [String], issues: [PersistenceReconciliationIssue]) {
        let stagingRoot = artifactRoot.appendingPathComponent(".staging", isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: stagingRoot, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        let payloads = enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "payload" }
        var paths: [String] = []
        var issues: [PersistenceReconciliationIssue] = []
        for payload in payloads {
            let artifactDirectory = payload.deletingLastPathComponent()
            guard let artifactID = UUID(uuidString: artifactDirectory.lastPathComponent),
                  !knownArtifactIDs.contains(artifactID) else { continue }
            do {
                try fileManager.removeItem(at: artifactDirectory)
                paths.append(payload.path)
            } catch {
                issues.append(cleanupIssue(
                    artifactID: artifactID,
                    path: payload.path,
                    error: error
                ))
            }
        }
        return (paths, issues)
    }
}

private enum PersistenceMaintenanceError: Error {
    case digestMismatch
}
