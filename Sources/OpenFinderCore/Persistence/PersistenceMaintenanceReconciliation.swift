import CryptoKit
import Foundation

extension PersistenceMaintenance {
    func inspectArtifacts(
        _ artifacts: [UUID: ArtifactSnapshot]
    ) -> (healthyIDs: Set<UUID>, issues: [PersistenceReconciliationIssue]) {
        var healthyIDs: Set<UUID> = []
        var issues: [PersistenceReconciliationIssue] = []
        for artifact in artifacts.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let url: URL
            do {
                url = try confinedArtifactURL(relativePath: artifact.relativePath)
            } catch {
                issues.append(.init(
                    kind: .corruptArtifactRow,
                    artifactID: artifact.id,
                    path: artifact.relativePath,
                    detail: "Artifact path is not confined: \(error)"
                ))
                continue
            }
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

    func removeArtifactRowThenFile(_ artifact: ArtifactSnapshot) async throws {
        let url = try confinedArtifactURL(relativePath: artifact.relativePath)
        let removal = ArtifactFileRemoval(fileManager: fileManager, url: url)
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
            guard let artifactID = UUID(uuidString: artifactDirectory.lastPathComponent) else {
                issues.append(.init(
                    kind: .corruptArtifactRow,
                    path: payload.path,
                    detail: "Staging artifact directory has an invalid UUID."
                ))
                continue
            }
            guard !knownArtifactIDs.contains(artifactID) else { continue }
            do {
                try verifyNoSymlink(at: artifactDirectory)
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

    func removeOrphanedPublished(
        knownArtifactIDs: Set<UUID>,
        knownRelativePaths: Set<String>
    ) -> (artifactIDs: [UUID], issues: [PersistenceReconciliationIssue]) {
        let publishedRoot = artifactRoot.appendingPathComponent("published", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: publishedRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else { return ([], []) }
        let files = enumerator.compactMap { $0 as? URL }
            .sorted { $0.path < $1.path }
        var artifactIDs: [UUID] = []
        var issues: [PersistenceReconciliationIssue] = []
        for file in files {
            let values: URLResourceValues
            do {
                values = try file.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                issues.append(cleanupIssue(path: file.path, error: error))
                continue
            }
            guard values.isDirectory != true else { continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                issues.append(.init(
                    kind: .corruptArtifactRow,
                    path: file.path,
                    detail: "Published artifact is not a confined regular file."
                ))
                continue
            }
            let relativePath = String(file.path.dropFirst(artifactRoot.path.count + 1))
            let artifactDirectory = file.deletingLastPathComponent()
            guard let artifactID = UUID(uuidString: artifactDirectory.lastPathComponent) else {
                issues.append(.init(
                    kind: .corruptArtifactRow,
                    path: file.path,
                    detail: "Published artifact directory has an invalid UUID."
                ))
                continue
            }
            guard !knownArtifactIDs.contains(artifactID),
                  !knownRelativePaths.contains(relativePath) else { continue }
            do {
                try verifyNoSymlink(at: file)
                try fileManager.removeItem(at: artifactDirectory)
                artifactIDs.append(artifactID)
            } catch {
                issues.append(cleanupIssue(
                    artifactID: artifactID,
                    path: file.path,
                    error: error
                ))
            }
        }
        return (artifactIDs, issues)
    }

    private func confinedArtifactURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !NSString(string: relativePath).isAbsolutePath else {
            throw PersistenceMaintenanceError.unconfinedPath
        }
        let url = artifactRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(artifactRoot.path + "/") else {
            throw PersistenceMaintenanceError.unconfinedPath
        }
        try verifyNoSymlink(at: url)
        return url
    }

    private func verifyNoSymlink(at url: URL) throws {
        let relative = String(url.path.dropFirst(artifactRoot.path.count))
        var candidate = artifactRoot
        for component in NSString(string: relative).pathComponents where component != "/" {
            candidate.appendPathComponent(component)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            if try candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw PersistenceMaintenanceError.symbolicLink
            }
        }
    }
}

private enum PersistenceMaintenanceError: Error {
    case digestMismatch, symbolicLink, unconfinedPath
}

private struct ArtifactFileRemoval: @unchecked Sendable {
    let fileManager: FileManager
    let url: URL

    func perform() throws {
        try fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: url.deletingLastPathComponent())
    }
}
