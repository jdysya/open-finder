import Foundation

public enum PersistenceReconciliationIssueKind: String, Sendable, Hashable {
    case missingArtifactFile
    case corruptArtifactFile
    case corruptArtifactRow
    case corruptMediaDocument
    case missingMediaAsset
    case orphanedMediaDocument
    case orphanedManagedTag
    case cleanupFailure
}

public struct PersistenceReconciliationIssue: Sendable, Hashable {
    public let kind: PersistenceReconciliationIssueKind
    public let artifactID: UUID?
    public let taskID: UUID?
    public let documentID: UUID?
    public let path: String
    public let detail: String

    public init(
        kind: PersistenceReconciliationIssueKind,
        artifactID: UUID? = nil,
        taskID: UUID? = nil,
        documentID: UUID? = nil,
        path: String = "",
        detail: String
    ) {
        self.kind = kind
        self.artifactID = artifactID
        self.taskID = taskID
        self.documentID = documentID
        self.path = path
        self.detail = detail
    }
}

public struct PersistenceMaintenanceReport: Sendable, Hashable {
    public let removedTaskIDs: [UUID]
    public let removedArtifactIDs: [UUID]
    public let removedStagingPaths: [String]
    public let issues: [PersistenceReconciliationIssue]

    public init(
        removedTaskIDs: [UUID],
        removedArtifactIDs: [UUID],
        removedStagingPaths: [String],
        issues: [PersistenceReconciliationIssue]
    ) {
        self.removedTaskIDs = removedTaskIDs
        self.removedArtifactIDs = removedArtifactIDs
        self.removedStagingPaths = removedStagingPaths
        self.issues = issues
    }
}
