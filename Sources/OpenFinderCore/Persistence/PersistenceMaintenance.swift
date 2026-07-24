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

            var removedArtifacts: [UUID] = []
            let referencedIDs = Set(snapshot.documents.values.flatMap(\.artifactIDs))
            let protectedIDs = pinnedArtifactIDs.union(referencedIDs)
            var remainingLinks = snapshot.links
            var removedTasks: [UUID] = []
            for task in snapshot.expiredTasks {
                let artifactIDs = remainingLinks
                    .filter { $0.value.contains(task.id) }
                    .map(\.key)
                    .sorted { $0.uuidString < $1.uuidString }
                do {
                    try await removeLinks(taskID: task.id)
                    for artifactID in artifactIDs {
                        remainingLinks[artifactID]?.remove(task.id)
                        guard remainingLinks[artifactID]?.isEmpty != false,
                              !protectedIDs.contains(artifactID),
                              inspection.healthyIDs.contains(artifactID),
                              let artifact = snapshot.artifacts[artifactID] else { continue }
                        do {
                            try await removeArtifactRow(artifactID)
                            try removeArtifactFile(artifact)
                            removedArtifacts.append(artifactID)
                        } catch {
                            issues.append(cleanupIssue(
                                artifactID: artifactID,
                                taskID: task.id,
                                path: artifact.relativePath,
                                error: error
                            ))
                        }
                    }
                    try await removeTaskRecord(task.id)
                    removedTasks.append(task.id)
                } catch {
                    issues.append(cleanupIssue(taskID: task.id, error: error))
                }
            }

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
            return Snapshot(
                artifacts: Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) }),
                links: Dictionary(grouping: links, by: \.artifactID)
                    .mapValues { Set($0.map(\.taskID)) },
                documents: Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) }),
                expiredTasks: tasks,
                issues: []
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
    let expiredTasks: [ExpiredTaskSnapshot]
    let issues: [PersistenceReconciliationIssue]
}
