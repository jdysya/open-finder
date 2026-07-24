import CryptoKit
import Foundation
import GRDB

public actor PersistenceMaintenance {
    public typealias Clock = @Sendable () -> Date

    let databasePool: DatabasePool
    let artifactRoot: URL
    let fileManager: FileManager
    private let clock: Clock

    public init(
        databasePool: DatabasePool,
        artifactRoot: URL,
        fileManager: FileManager = .default,
        clock: @escaping Clock = { .now }
    ) {
        self.databasePool = databasePool
        self.artifactRoot = artifactRoot.standardizedFileURL
        self.fileManager = fileManager
        self.clock = clock
    }

    public func runAtStartup(
        pinnedArtifactIDs: Set<UUID> = []
    ) async -> PersistenceMaintenanceReport {
        await run(pinnedArtifactIDs: pinnedArtifactIDs)
    }

    public func runPeriodically(
        pinnedArtifactIDs: Set<UUID> = []
    ) async -> PersistenceMaintenanceReport {
        await run(pinnedArtifactIDs: pinnedArtifactIDs)
    }

    private func run(pinnedArtifactIDs: Set<UUID>) async -> PersistenceMaintenanceReport {
        let now = clock()
        do {
            let snapshot = try await loadSnapshot(now: now)
            var issues = snapshot.issues
            let inspection = inspectArtifacts(snapshot.artifacts)
            issues.append(contentsOf: inspection.issues)
            issues.append(contentsOf: missingMediaIssues(
                documents: snapshot.documents,
                artifacts: snapshot.artifacts,
                healthyArtifactIDs: inspection.healthyIDs
            ))
            await persistArtifactDiagnostics(inspection.issues, now: now)

            let staging = removeOrphanedStaging(knownArtifactIDs: Set(snapshot.artifacts.keys))
            issues.append(contentsOf: staging.issues)

            let mediaCleanup = await removeOrphanedMedia(
                documents: snapshot.documents,
                documentRowIDs: snapshot.documentRowIDs,
                tags: snapshot.tags,
                taskIDs: snapshot.taskIDs
            )
            issues.append(contentsOf: mediaCleanup)

            var remainingLinks = snapshot.links
            var removedTasks: [UUID] = []
            for task in snapshot.expiredTasks
            where !snapshot.diagnosticProtectedTaskIDs.contains(task.id) {
                do {
                    try await removeLinks(taskID: task.id)
                    for artifactID in remainingLinks.keys {
                        remainingLinks[artifactID]?.remove(task.id)
                    }
                    try await removeTaskRecord(task.id)
                    removedTasks.append(task.id)
                } catch {
                    issues.append(cleanupIssue(taskID: task.id, error: error))
                }
            }

            let retainedDocuments = snapshot.documents.values.filter {
                snapshot.taskIDs.contains($0.taskID) && !removedTasks.contains($0.taskID)
            }
            let referencedIDs = Set(retainedDocuments.flatMap(\.artifactIDs))
            let protectedIDs = pinnedArtifactIDs.union(referencedIDs)
            var removedArtifacts: [UUID] = []
            for artifact in snapshot.artifacts.values.sorted(by: { $0.id.uuidString < $1.id.uuidString })
            where remainingLinks[artifact.id]?.isEmpty != false
                && !protectedIDs.contains(artifact.id)
                && inspection.healthyIDs.contains(artifact.id) {
                do {
                    try await removeArtifactRowThenFile(artifact)
                    removedArtifacts.append(artifact.id)
                } catch {
                    let issue = cleanupIssue(
                        artifactID: artifact.id,
                        path: artifact.relativePath,
                        error: error
                    )
                    issues.append(issue)
                    await persistArtifactDiagnostics([issue], now: now)
                }
            }
            let retainedPaths = Set(snapshot.artifacts.values.compactMap {
                removedArtifacts.contains($0.id) ? nil : $0.relativePath
            })
            let published = removeOrphanedPublished(
                knownArtifactIDs: Set(snapshot.artifacts.keys).subtracting(removedArtifacts),
                knownRelativePaths: retainedPaths
            )
            removedArtifacts.append(contentsOf: published.artifactIDs)
            issues.append(contentsOf: published.issues)

            return report(
                removedTasks: removedTasks,
                removedArtifacts: removedArtifacts,
                removedStaging: staging.paths,
                issues: issues
            )
        } catch {
            return report(
                issues: [.init(
                    kind: .cleanupFailure,
                    detail: "Persistence maintenance could not read the database: \(error)"
                )]
            )
        }
    }

    private func loadSnapshot(now: Date) async throws -> Snapshot {
        try await databasePool.read { db in
            let artifacts = try ArtifactSnapshot.fetchAll(db)
            let links = try ArtifactLinkSnapshot.fetchAll(db)
            let documents = try MediaDocumentSnapshot.fetchAll(db)
            let tasks = try ExpiredTaskSnapshot.fetchAll(db, now: now)
            let tags = try ManagedTagSnapshot.fetchAll(db)
            return Snapshot(
                artifacts: Dictionary(uniqueKeysWithValues: artifacts.records.map { ($0.id, $0) }),
                links: Dictionary(grouping: links, by: \.artifactID)
                    .mapValues { Set($0.map(\.taskID)) },
                documents: Dictionary(uniqueKeysWithValues: documents.records.map { ($0.id, $0) }),
                documentRowIDs: documents.rowIDs,
                tags: tags,
                taskIDs: try TaskIDSnapshot.fetchAll(db),
                diagnosticProtectedTaskIDs: Set(documents.issues.compactMap(\.taskID)),
                expiredTasks: tasks,
                issues: artifacts.issues + documents.issues
            )
        }
    }

    func cleanupIssue(
        artifactID: UUID? = nil,
        taskID: UUID? = nil,
        path: String = "",
        error: Error
    ) -> PersistenceReconciliationIssue {
        .init(
            kind: .cleanupFailure,
            artifactID: artifactID,
            taskID: taskID,
            path: path,
            detail: "Cleanup failed: \(error)"
        )
    }

    func report(
        removedTasks: [UUID] = [],
        removedArtifacts: [UUID] = [],
        removedStaging: [String] = [],
        issues: [PersistenceReconciliationIssue]
    ) -> PersistenceMaintenanceReport {
        .init(
            removedTaskIDs: removedTasks.sorted { $0.uuidString < $1.uuidString },
            removedArtifactIDs: removedArtifacts.sorted { $0.uuidString < $1.uuidString },
            removedStagingPaths: removedStaging.sorted(),
            issues: issues.sorted {
                ($0.kind.rawValue, $0.path, $0.detail) < ($1.kind.rawValue, $1.path, $1.detail)
            }
        )
    }
}

private struct Snapshot: Sendable {
    let artifacts: [UUID: ArtifactSnapshot]
    let links: [UUID: Set<UUID>]
    let documents: [UUID: MediaDocumentSnapshot]
    let documentRowIDs: Set<String>
    let tags: [ManagedTagSnapshot]
    let taskIDs: Set<UUID>
    let diagnosticProtectedTaskIDs: Set<UUID>
    let expiredTasks: [ExpiredTaskSnapshot]
    let issues: [PersistenceReconciliationIssue]
}

extension PersistenceMaintenance {
    func removeOrphanedMedia(
        documents: [UUID: MediaDocumentSnapshot],
        documentRowIDs: Set<String>,
        tags: [ManagedTagSnapshot],
        taskIDs: Set<UUID>
    ) async -> [PersistenceReconciliationIssue] {
        var issues: [PersistenceReconciliationIssue] = []
        for tag in tags where !documentRowIDs.contains(tag.documentID) {
            do {
                try await databasePool.write { db in
                    try db.execute(
                        sql: "DELETE FROM media_managed_tags WHERE document_id = ?",
                        arguments: [tag.documentID]
                    )
                }
                issues.append(.init(
                    kind: .orphanedManagedTag,
                    documentID: UUID(uuidString: tag.documentID),
                    detail: "Managed tag referenced a missing media document and was removed."
                ))
            } catch {
                issues.append(cleanupIssue(error: error))
            }
        }
        for document in documents.values.sorted(by: { $0.id.uuidString < $1.id.uuidString })
        where !taskIDs.contains(document.taskID) {
            do {
                try await databasePool.write { db in
                    try db.execute(
                        sql: "DELETE FROM media_analysis_documents WHERE document_id = ?",
                        arguments: [document.id.uuidString]
                    )
                }
                issues.append(.init(
                    kind: .orphanedMediaDocument,
                    taskID: document.taskID,
                    documentID: document.id,
                    detail: "Media document referenced a missing task and was removed."
                ))
            } catch {
                issues.append(cleanupIssue(taskID: document.taskID, error: error))
            }
        }
        return issues
    }
}
