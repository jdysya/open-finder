import Foundation
import GRDB

public enum TaskStoreMode: Sendable {
    case shadowWrite
    case durable
}

public enum GRDBTaskStoreError: Error, Equatable {
    case descriptorRecordMismatch
    case queueOrdinalOutOfRange
    case durableReadUnavailable
    case malformedPersistedTask
}

public final class GRDBTaskStore: TaskStore, Sendable {
    private let databasePool: DatabasePool
    private let mode: TaskStoreMode

    public init(database: AppDatabase, mode: TaskStoreMode) {
        databasePool = database.databasePool
        self.mode = mode
    }

    public func enqueue(
        descriptor: TaskDescriptorEnvelope,
        record: TaskRecord
    ) async throws {
        guard descriptor.taskID == record.id, descriptor == record.descriptor else {
            throw GRDBTaskStoreError.descriptorRecordMismatch
        }
        guard descriptor.queueOrdinal <= UInt64(Int64.max) else {
            throw GRDBTaskStoreError.queueOrdinalOutOfRange
        }
        let descriptorPayload = try JSONEncoder().encode(descriptor.redactedPayload)
        let kindPayload = try JSONEncoder().encode(record.kind)
        let progressDetail = try record.progressDetail.map { try JSONEncoder().encode($0) }

        try await write { db in
            try db.execute(
                sql: """
                    INSERT INTO task_descriptors (
                        task_id, schema_version, handler_id, payload_version,
                        redacted_payload, root_task_id, parent_task_id, attempt,
                        resource_key, idempotency_key, queue_ordinal, created_at
                    ) VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    descriptor.taskID.uuidString,
                    descriptor.handlerID,
                    descriptor.payloadVersion,
                    descriptorPayload,
                    descriptor.lineage.rootTaskID.uuidString,
                    descriptor.lineage.parentTaskID?.uuidString,
                    descriptor.lineage.attempt,
                    descriptor.resourceKey,
                    descriptor.idempotencyKey,
                    Int64(descriptor.queueOrdinal),
                    record.createdAt.timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO task_records (
                        task_id, record_version, kind_payload, title, status,
                        status_reason, progress, progress_detail, created_at,
                        started_at, finished_at, input_summary, result_summary,
                        error_message, log_file_path, retry_count, clipboard_text,
                        effects_committed_at
                    ) VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [
                    record.id.uuidString,
                    kindPayload,
                    record.title,
                    record.status.rawValue,
                    record.reasonCode?.rawValue,
                    record.progress,
                    progressDetail,
                    record.createdAt.timeIntervalSince1970,
                    record.startedAt?.timeIntervalSince1970,
                    record.finishedAt?.timeIntervalSince1970,
                    record.inputSummary,
                    record.resultSummary,
                    record.errorMessage,
                    record.logFilePath,
                    record.retryCount,
                    record.clipboardText
                ]
            )
        }
    }

    public func update(
        record: TaskRecord,
        effectsCommitted: Bool
    ) async throws {
        let kindPayload = try JSONEncoder().encode(record.kind)
        let progressDetail = try record.progressDetail.map { try JSONEncoder().encode($0) }
        let committedAt = Date().timeIntervalSince1970

        try await write { db in
            try db.execute(
                sql: """
                    UPDATE task_records
                    SET kind_payload = ?, title = ?, status = ?, status_reason = ?,
                        progress = ?, progress_detail = ?, created_at = ?,
                        started_at = ?, finished_at = ?, input_summary = ?,
                        result_summary = ?, error_message = ?, log_file_path = ?,
                        retry_count = ?, clipboard_text = ?,
                        effects_committed_at = CASE
                            WHEN ? THEN COALESCE(effects_committed_at, ?)
                            ELSE effects_committed_at
                        END
                    WHERE task_id = ?
                    """,
                arguments: [
                    kindPayload,
                    record.title,
                    record.status.rawValue,
                    record.reasonCode?.rawValue,
                    record.progress,
                    progressDetail,
                    record.createdAt.timeIntervalSince1970,
                    record.startedAt?.timeIntervalSince1970,
                    record.finishedAt?.timeIntervalSince1970,
                    record.inputSummary,
                    record.resultSummary,
                    record.errorMessage,
                    record.logFilePath,
                    record.retryCount,
                    record.clipboardText,
                    effectsCommitted,
                    committedAt,
                    record.id.uuidString
                ]
            )
        }
    }

    public func append(log: TaskLogLine) async throws {
        try await write { db in
            let sequence = try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(MAX(sequence), -1) + 1
                    FROM task_logs WHERE task_id = ?
                    """,
                arguments: [log.taskID.uuidString]
            ) ?? 0
            try db.execute(
                sql: """
                    INSERT INTO task_logs (task_id, sequence, logged_at, level, message)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    log.taskID.uuidString,
                    sequence,
                    log.date.timeIntervalSince1970,
                    log.level,
                    log.message
                ]
            )
        }
    }

    public func interruptActiveTasks(at date: Date = Date()) async throws {
        try requireDurableRead()
        try await databasePool.write { db in
            try db.execute(
                sql: """
                    UPDATE task_records
                    SET status = ?, status_reason = ?,
                        finished_at = MAX(created_at, ?)
                    WHERE status IN (?, ?)
                    """,
                arguments: [
                    TaskStatus.interrupted.rawValue,
                    TaskStatusReasonCode.recoveryInterrupted.rawValue,
                    date.timeIntervalSince1970,
                    TaskStatus.running.rawValue,
                    TaskStatus.cancelling.rawValue,
                ]
            )
        }
    }

    public func loadPersistedTasks() async throws -> [PersistedTaskState] {
        try requireDurableRead()
        return try await databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        d.task_id, d.handler_id, d.payload_version, d.redacted_payload,
                        d.root_task_id, d.parent_task_id, d.attempt, d.resource_key,
                        d.idempotency_key, d.queue_ordinal,
                        r.kind_payload, r.title, r.status, r.status_reason, r.progress,
                        r.progress_detail, r.created_at, r.started_at, r.finished_at,
                        r.input_summary, r.result_summary, r.error_message,
                        r.log_file_path, r.retry_count, r.clipboard_text
                    FROM task_descriptors d
                    JOIN task_records r ON r.task_id = d.task_id
                    ORDER BY d.queue_ordinal
                    """
            )
            return try rows.map { row in
                try Self.decodePersistedTask(row, db: db)
            }
        }
    }

    public func link(artifactID: UUID, to taskID: UUID, ordinal: Int) async throws {
        try await write { db in
            try db.execute(
                sql: """
                    INSERT INTO task_artifacts (task_id, artifact_id, ordinal, linked_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    taskID.uuidString,
                    artifactID.uuidString,
                    ordinal,
                    Date().timeIntervalSince1970
                ]
            )
        }
    }

    private func write(
        _ updates: @escaping @Sendable (Database) throws -> Void
    ) async throws {
        do {
            try await databasePool.write(updates)
        } catch {
            guard mode == .shadowWrite else { throw error }
        }
    }

    private func requireDurableRead() throws {
        guard mode == .durable else {
            throw GRDBTaskStoreError.durableReadUnavailable
        }
    }

    private static func decodePersistedTask(
        _ row: Row,
        db: Database
    ) throws -> PersistedTaskState {
        guard
            let taskID = UUID(uuidString: row["task_id"]),
            let rootTaskID = UUID(uuidString: row["root_task_id"]),
            let status = TaskStatus(rawValue: row["status"]),
            let queueOrdinal = UInt64(exactly: row["queue_ordinal"] as Int64)
        else {
            throw GRDBTaskStoreError.malformedPersistedTask
        }
        let parentTaskID: UUID?
        if let parent: String = row["parent_task_id"] {
            guard let decoded = UUID(uuidString: parent) else {
                throw GRDBTaskStoreError.malformedPersistedTask
            }
            parentTaskID = decoded
        } else {
            parentTaskID = nil
        }
        let redactedPayloadData: Data = row["redacted_payload"]
        let kindPayload: Data = row["kind_payload"]
        let progressDetailData: Data? = row["progress_detail"]
        let descriptor = TaskDescriptorEnvelope(
            taskID: taskID,
            handlerID: row["handler_id"],
            payloadVersion: row["payload_version"],
            resourceKey: row["resource_key"],
            idempotencyKey: row["idempotency_key"],
            lineage: .init(
                rootTaskID: rootTaskID,
                parentTaskID: parentTaskID,
                attempt: row["attempt"]
            ),
            queueOrdinal: queueOrdinal,
            redactedPayload: try JSONDecoder().decode(
                [String: String].self,
                from: redactedPayloadData
            )
        )
        let reasonRaw: String? = row["status_reason"]
        let record = TaskRecord(
            id: taskID,
            kind: try JSONDecoder().decode(TaskKind.self, from: kindPayload),
            title: row["title"],
            status: status,
            progress: row["progress"],
            progressDetail: try progressDetailData.map {
                try JSONDecoder().decode(TaskProgressSnapshot.self, from: $0)
            },
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            startedAt: (row["started_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            finishedAt: (row["finished_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            inputSummary: row["input_summary"],
            resultSummary: row["result_summary"],
            errorMessage: row["error_message"],
            logFilePath: row["log_file_path"],
            retryCount: row["retry_count"],
            clipboardText: row["clipboard_text"],
            descriptor: descriptor,
            reasonCode: reasonRaw.flatMap(TaskStatusReasonCode.init(rawValue:))
        )
        let logRows = try Row.fetchAll(
            db,
            sql: """
                SELECT sequence, logged_at, level, message
                FROM task_logs
                WHERE task_id = ?
                ORDER BY sequence
                """,
            arguments: [taskID.uuidString]
        )
        let logs = logRows.map { logRow in
            TaskLogLine(
                id: deterministicLogID(taskID: taskID, sequence: logRow["sequence"]),
                taskID: taskID,
                date: Date(timeIntervalSince1970: logRow["logged_at"]),
                level: logRow["level"],
                message: logRow["message"]
            )
        }
        return PersistedTaskState(descriptor: descriptor, record: record, logs: logs)
    }

    private static func deterministicLogID(taskID: UUID, sequence: Int64) -> UUID {
        var bytes = taskID.uuid
        withUnsafeMutableBytes(of: &bytes) { buffer in
            var encoded = UInt64(bitPattern: sequence).bigEndian
            withUnsafeBytes(of: &encoded) { sequenceBytes in
                for index in sequenceBytes.indices {
                    buffer[8 + index] ^= sequenceBytes[index]
                }
            }
        }
        return UUID(uuid: bytes)
    }
}
