import Foundation
import GRDB

struct ArtifactSnapshot: Sendable {
    let id: UUID
    let relativePath: String
    let byteCount: Int
    let sha256: String

    static func fetchAll(_ db: Database) throws -> (records: [Self], issues: [PersistenceReconciliationIssue]) {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT artifact_id, relative_path, byte_count, sha256
                FROM artifact_records
                """
        )
        var records: [Self] = []
        var issues: [PersistenceReconciliationIssue] = []
        for row in rows {
            let rawID: String = row["artifact_id"]
            guard let id = UUID(uuidString: rawID) else {
                issues.append(.init(
                    kind: .corruptArtifactRow,
                    detail: "Artifact row has an invalid UUID: \(rawID)"
                ))
                continue
            }
            records.append(Self(
                id: id,
                relativePath: row["relative_path"],
                byteCount: row["byte_count"],
                sha256: row["sha256"]
            ))
        }
        return (records, issues)
    }
}

struct ArtifactLinkSnapshot: Sendable {
    let artifactID: UUID
    let taskID: UUID

    static func fetchAll(_ db: Database) throws -> [Self] {
        try Row.fetchAll(db, sql: "SELECT artifact_id, task_id FROM task_artifacts")
            .compactMap { row in
                guard
                    let artifactID = UUID(uuidString: row["artifact_id"]),
                    let taskID = UUID(uuidString: row["task_id"])
                else { return nil }
                return Self(artifactID: artifactID, taskID: taskID)
            }
    }
}

struct MediaDocumentSnapshot: Sendable {
    let id: UUID
    let taskID: UUID
    let artifactIDs: Set<UUID>

    static func fetchAll(
        _ db: Database
    ) throws -> (records: [Self], rowIDs: Set<String>, issues: [PersistenceReconciliationIssue]) {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT document_id, task_id, schema_id, schema_version, payload FROM media_analysis_documents"
        )
        var records: [Self] = []
        var issues: [PersistenceReconciliationIssue] = []
        for row in rows {
            let rawID: String = row["document_id"]
            let rawTaskID: String = row["task_id"]
            do {
                guard
                    let id = UUID(uuidString: rawID),
                    let taskID = UUID(uuidString: rawTaskID),
                    row["schema_id"] as String == MediaAnalysisDocument.schemaIdentifier,
                    row["schema_version"] as Int == MediaAnalysisDocument.currentSchemaVersion
                else { throw PersistenceRecordError.invalidMediaMetadata }
                let document = try JSONDecoder().decode(
                    MediaAnalysisDocument.self,
                    from: row["payload"] as Data
                )
                guard document.documentID == id, document.taskID == taskID else {
                    throw PersistenceRecordError.mediaIdentityMismatch
                }
                let artifactIDs = document.items.reduce(into: Set<UUID>()) { result, item in
                    result.formUnion(item.moments.flatMap(\.assets).map(\.artifactID))
                    if let report = item.report { result.insert(report.artifactID) }
                }
                records.append(Self(id: id, taskID: taskID, artifactIDs: artifactIDs))
            } catch {
                issues.append(.init(
                    kind: .corruptMediaDocument,
                    taskID: UUID(uuidString: rawTaskID),
                    documentID: UUID(uuidString: rawID),
                    detail: "Media document row is invalid: \(error)"
                ))
            }
        }
        return (records, Set(rows.map { $0["document_id"] as String }), issues)
    }
}

struct ManagedTagSnapshot: Sendable {
    let documentID: String

    static func fetchAll(_ db: Database) throws -> [Self] {
        try String.fetchAll(
            db,
            sql: "SELECT DISTINCT document_id FROM media_managed_tags ORDER BY document_id"
        ).map(Self.init)
    }
}

struct TaskIDSnapshot {
    static func fetchAll(_ db: Database) throws -> Set<UUID> {
        Set(try String.fetchAll(db, sql: "SELECT task_id FROM task_records").compactMap(UUID.init))
    }
}

struct ExpiredTaskSnapshot: Sendable {
    let id: UUID

    static func fetchAll(_ db: Database, now: Date) throws -> [Self] {
        let cutoff = now.addingTimeInterval(-ArtifactRecord.retentionInterval)
        return try String.fetchAll(
            db,
            sql: """
                SELECT task_id
                FROM task_records
                WHERE status IN ('succeeded', 'failed', 'cancelled', 'interrupted', 'unavailable')
                  AND finished_at IS NOT NULL
                  AND finished_at <= ?
                ORDER BY finished_at, task_id
                """,
            arguments: [cutoff.timeIntervalSince1970]
        ).compactMap { UUID(uuidString: $0) }.map(Self.init)
    }
}

private enum PersistenceRecordError: Error {
    case invalidMediaMetadata
    case mediaIdentityMismatch
}
