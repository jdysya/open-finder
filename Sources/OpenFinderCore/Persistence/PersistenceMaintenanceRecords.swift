import Foundation
import GRDB

struct ArtifactSnapshot: Sendable {
    let id: UUID
    let relativePath: String
    let byteCount: Int
    let sha256: String

    static func fetchAll(_ db: Database) throws -> [Self] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT artifact_id, relative_path, byte_count, sha256
                FROM artifact_records
                """
        ).compactMap { row in
            guard let id = UUID(uuidString: row["artifact_id"]) else { return nil }
            return Self(
                id: id,
                relativePath: row["relative_path"],
                byteCount: row["byte_count"],
                sha256: row["sha256"]
            )
        }
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

    static func fetchAll(_ db: Database) throws -> [Self] {
        try Row.fetchAll(
            db,
            sql: "SELECT document_id, task_id, schema_id, schema_version, payload FROM media_analysis_documents"
        ).compactMap { row in
            guard
                let id = UUID(uuidString: row["document_id"]),
                let taskID = UUID(uuidString: row["task_id"]),
                row["schema_id"] as String == MediaAnalysisDocument.schemaIdentifier,
                row["schema_version"] as Int == MediaAnalysisDocument.currentSchemaVersion,
                let object = try? JSONSerialization.jsonObject(with: row["payload"] as Data),
                let dictionary = object as? [String: Any]
            else { return nil }
            return Self(
                id: id,
                taskID: taskID,
                artifactIDs: referencedArtifactIDs(in: dictionary)
            )
        }
    }

    private static func referencedArtifactIDs(in value: Any) -> Set<UUID> {
        if let dictionary = value as? [String: Any] {
            var ids = Set(dictionary.compactMap { key, value -> UUID? in
                guard key == "artifactID", let raw = value as? String else { return nil }
                return UUID(uuidString: raw)
            })
            for nested in dictionary.values {
                ids.formUnion(referencedArtifactIDs(in: nested))
            }
            return ids
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<UUID>()) {
                $0.formUnion(referencedArtifactIDs(in: $1))
            }
        }
        return []
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
