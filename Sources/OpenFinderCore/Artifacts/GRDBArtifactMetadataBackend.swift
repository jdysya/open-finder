import Foundation
import GRDB

public final class GRDBArtifactMetadataBackend: ArtifactMetadataBackend, Sendable {
    private let databasePool: DatabasePool

    public init(database: AppDatabase) {
        databasePool = database.databasePool
    }

    public func upsert(_ record: ArtifactRecord, taskID: UUID) async throws {
        try record.validate()
        try await databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO artifact_records (
                        artifact_id, record_version, schema_id, state, relative_path,
                        media_type, byte_count, sha256, staged_at, finished_at,
                        retention_deadline, reconciliation_state
                    ) VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(artifact_id) DO UPDATE SET
                        schema_id = excluded.schema_id,
                        state = excluded.state,
                        relative_path = excluded.relative_path,
                        media_type = excluded.media_type,
                        byte_count = excluded.byte_count,
                        sha256 = excluded.sha256,
                        staged_at = excluded.staged_at,
                        finished_at = excluded.finished_at,
                        retention_deadline = excluded.retention_deadline,
                        reconciliation_state = excluded.reconciliation_state
                    """,
                arguments: Self.arguments(for: record)
            )
            let ordinal = try Int.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(MAX(ordinal), -1) + 1
                    FROM task_artifacts WHERE task_id = ?
                    """,
                arguments: [taskID.uuidString]
            ) ?? 0
            try db.execute(
                sql: """
                    INSERT INTO task_artifacts (task_id, artifact_id, ordinal, linked_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(task_id, artifact_id) DO NOTHING
                    """,
                arguments: [
                    taskID.uuidString,
                    record.id.uuidString,
                    ordinal,
                    Date().timeIntervalSince1970
                ]
            )
        }
    }

    public func record(id: UUID) async -> ArtifactRecord? {
        try? await databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "\(Self.recordSelection) WHERE artifact_id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.record(from: row)
        }
    }

    public func entries() async -> [ArtifactMetadataEntry] {
        (try? await databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT task_artifacts.task_id, \(Self.qualifiedRecordSelection)
                    FROM artifact_records
                    JOIN task_artifacts USING (artifact_id)
                    ORDER BY artifact_records.artifact_id
                    """
            ).map { row in
                guard let taskID = UUID(uuidString: row["task_id"]) else {
                    throw GRDBTaskStoreError.malformedPersistedTask
                }
                return ArtifactMetadataEntry(
                    taskID: taskID,
                    record: try Self.record(from: row)
                )
            }
        }) ?? []
    }

    public func remove(id: UUID) async {
        try? await databasePool.write { db in
            try db.execute(
                sql: "DELETE FROM task_artifacts WHERE artifact_id = ?",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM artifact_records WHERE artifact_id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    public func link(_ artifactID: UUID, to taskID: UUID) async throws {
        try await databasePool.read { db in
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM task_artifacts
                        WHERE task_id = ? AND artifact_id = ?
                    )
                    """,
                arguments: [taskID.uuidString, artifactID.uuidString]
            ) == true else {
                throw ArtifactStoreError.metadataRecordMissing(artifactID)
            }
        }
    }

    public func isLinked(_ artifactID: UUID, to taskID: UUID) async -> Bool {
        (try? await databasePool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM task_artifacts
                        WHERE task_id = ? AND artifact_id = ?
                    )
                    """,
                arguments: [taskID.uuidString, artifactID.uuidString]
            ) == true
        }) ?? false
    }

    public func markTaskEffectsCommitted(_ taskID: UUID) async throws {
        try await databasePool.write { db in
            try db.execute(
                sql: """
                    UPDATE task_records
                    SET effects_committed_at = COALESCE(effects_committed_at, ?)
                    WHERE task_id = ?
                    """,
                arguments: [Date().timeIntervalSince1970, taskID.uuidString]
            )
        }
    }

    public func taskEffectsCommitted(_ taskID: UUID) async -> Bool {
        (try? await databasePool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT effects_committed_at IS NOT NULL
                    FROM task_records WHERE task_id = ?
                    """,
                arguments: [taskID.uuidString]
            ) == true
        }) ?? false
    }

    public func recordCleanupFailure(taskID: UUID, message: String) async {
        try? await databasePool.write { db in
            try db.execute(
                sql: """
                    UPDATE artifact_records
                    SET cleanup_attempts = cleanup_attempts + 1,
                        reconciliation_reason = ?
                    WHERE artifact_id IN (
                        SELECT artifact_id FROM task_artifacts WHERE task_id = ?
                    )
                    """,
                arguments: [message, taskID.uuidString]
            )
        }
    }

    public func cleanupFailure(taskID: UUID) async -> String? {
        try? await databasePool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT reconciliation_reason
                    FROM artifact_records
                    WHERE reconciliation_reason IS NOT NULL
                        AND artifact_id IN (
                            SELECT artifact_id FROM task_artifacts WHERE task_id = ?
                        )
                    ORDER BY artifact_id
                    LIMIT 1
                    """,
                arguments: [taskID.uuidString]
            )
        }
    }

    public func clearCleanupFailure(taskID: UUID) async {
        try? await databasePool.write { db in
            try db.execute(
                sql: """
                    UPDATE artifact_records
                    SET reconciliation_reason = NULL
                    WHERE artifact_id IN (
                        SELECT artifact_id FROM task_artifacts WHERE task_id = ?
                    )
                    """,
                arguments: [taskID.uuidString]
            )
        }
    }

    private static let recordSelection = """
        SELECT artifact_id, schema_id, state, relative_path, media_type,
            byte_count, sha256, staged_at, finished_at
        FROM artifact_records
        """

    private static let qualifiedRecordSelection = """
        artifact_records.artifact_id, artifact_records.schema_id,
        artifact_records.state, artifact_records.relative_path,
        artifact_records.media_type, artifact_records.byte_count,
        artifact_records.sha256, artifact_records.staged_at,
        artifact_records.finished_at
        """

    private static func arguments(for record: ArtifactRecord) -> StatementArguments {
        [
            record.id.uuidString,
            record.schemaID,
            record.state.rawValue,
            record.relativePath,
            record.mediaType,
            record.byteCount,
            record.sha256,
            record.stagedAt.timeIntervalSince1970,
            record.finishedAt?.timeIntervalSince1970,
            record.retentionDeadline?.timeIntervalSince1970,
            record.reconciliationState.rawValue
        ]
    }

    private static func record(from row: Row) throws -> ArtifactRecord {
        guard
            let id = UUID(uuidString: row["artifact_id"]),
            let state = ArtifactLifecycleState(rawValue: row["state"])
        else {
            throw GRDBTaskStoreError.malformedPersistedTask
        }
        return ArtifactRecord(
            id: id,
            schemaID: row["schema_id"],
            relativePath: row["relative_path"],
            mediaType: row["media_type"],
            byteCount: row["byte_count"],
            sha256: row["sha256"],
            state: state,
            stagedAt: Date(timeIntervalSince1970: row["staged_at"]),
            finishedAt: (row["finished_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }
}
