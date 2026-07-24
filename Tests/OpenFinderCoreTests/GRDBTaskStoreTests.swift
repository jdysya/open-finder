import Foundation
import GRDB
import XCTest
@testable import OpenFinderCore

final class GRDBTaskStoreTests: XCTestCase {
    func testAtomicEnqueueLogsAndTerminalTransitions() async throws {
        let url = makeDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try AppDatabase(url: url)
        let store = GRDBTaskStore(database: database)
        let registry = TaskHandlerRegistry()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ) { _, events in
            await events.updateProgress(.init(
                fraction: 0.5,
                phase: "copy",
                detail: "half",
                completed: 1,
                total: 2,
                unit: "items"
            ))
            await events.appendLog("persisted log")
            try await events.markEffectsCommitted()
            return .success(summary: "copied", clipboard: "clipboard")
        })
        let queue = TaskQueueService(
            maxConcurrentTasks: 1,
            handlerRegistry: registry,
            store: store
        )
        let taskID = UUID()
        let artifactID = UUID()
        let descriptor = TaskDescriptorEnvelope(
            taskID: taskID,
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1,
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: 37,
            redactedPayload: ["source": "/tmp/source"]
        )
        try await database.databasePool.write { db in
            try Self.insertArtifact(artifactID, db: db)
        }

        let enqueuedID = try await queue.enqueue(.init(
            kind: .localCopy,
            title: "Persisted copy",
            inputSummary: "one item",
            descriptor: descriptor
        ))
        let terminal = try await queue.waitForTerminalStatus(enqueuedID, timeout: 2)
        try await store.link(artifactID: artifactID, to: taskID, ordinal: 0)

        XCTAssertEqual(terminal.status, .succeeded)
        try await database.databasePool.read { db in
            XCTAssertEqual(try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM task_descriptors WHERE task_id = ? AND queue_ordinal = 37",
                arguments: [taskID.uuidString]
            ), 1)
            XCTAssertEqual(try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM task_records WHERE task_id = ?",
                arguments: [taskID.uuidString]
            ), 1)
            let record = try Row.fetchOne(
                db,
                sql: """
                    SELECT status, progress, progress_detail, result_summary,
                           clipboard_text, effects_committed_at
                    FROM task_records WHERE task_id = ?
                    """,
                arguments: [taskID.uuidString]
            )
            XCTAssertEqual(record?["status"] as String?, TaskStatus.succeeded.rawValue)
            XCTAssertEqual(record?["progress"] as Double?, 1)
            let progressDetailData: Data? = record?["progress_detail"]
            let persistedProgress = try progressDetailData.map {
                try JSONDecoder().decode(TaskProgressSnapshot.self, from: $0)
            }
            XCTAssertEqual(persistedProgress?.fraction, 0.5)
            XCTAssertEqual(persistedProgress?.phase, "copy")
            XCTAssertEqual(record?["result_summary"] as String?, "copied")
            XCTAssertEqual(record?["clipboard_text"] as String?, "clipboard")
            XCTAssertNotNil(record?["effects_committed_at"] as Double?)
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT message FROM task_logs WHERE task_id = ? ORDER BY sequence",
                    arguments: [taskID.uuidString]
                ),
                ["copy: half", "persisted log"]
            )
            XCTAssertEqual(try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM task_artifacts
                    WHERE task_id = ? AND artifact_id = ? AND ordinal = 0
                    """,
                arguments: [taskID.uuidString, artifactID.uuidString]
            ), 1)
        }
    }

    func testDurableInsertFailurePreventsExecution() async throws {
        let url = makeDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try AppDatabase(url: url)
        try await database.databasePool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_task_record
                BEFORE INSERT ON task_records
                BEGIN
                    SELECT RAISE(ABORT, 'fixture task record rejection');
                END
                """)
        }
        let executions = ExecutionCounter()
        let registry = TaskHandlerRegistry()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ) { _, _ in
            await executions.increment()
            return .success(summary: "must not run", clipboard: nil)
        })
        let store = GRDBTaskStore(database: database)
        let queue = TaskQueueService(
            maxConcurrentTasks: 1,
            handlerRegistry: registry,
            store: store
        )
        let taskID = UUID()
        let descriptor = TaskDescriptorEnvelope(
            taskID: taskID,
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1,
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: 52
        )

        do {
            _ = try await queue.enqueue(.init(
                kind: .localCopy,
                title: "Rejected durable task",
                descriptor: descriptor
            ))
            XCTFail("Expected durable enqueue to fail")
        } catch {
            XCTAssertTrue(error is DatabaseError)
            let executionCount = await executions.value
            XCTAssertEqual(executionCount, 0)
        }

        try await database.databasePool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_descriptors"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_records"), 0)
        }
    }

    func testStartupInterruptsRunningAndCancellingInOneRecoveryStep() async throws {
        let url = makeDatabaseURL()
        defer { removeDatabase(at: url) }
        let store = GRDBTaskStore(database: try AppDatabase(url: url))
        for (ordinal, status) in [(61, TaskStatus.running), (62, .cancelling)] {
            let taskID = UUID()
            let descriptor = TaskDescriptorEnvelope(
                taskID: taskID,
                handlerID: DurableTaskHandlerID.transferMove.rawValue,
                payloadVersion: 1,
                resourceKey: "fixture:move",
                lineage: .init(rootTaskID: taskID),
                queueOrdinal: UInt64(ordinal)
            )
            try await store.enqueue(
                descriptor: descriptor,
                record: TaskRecord(
                    id: taskID,
                    kind: .localMove,
                    title: "Active move \(ordinal)",
                    status: status,
                    startedAt: Date(),
                    descriptor: descriptor
                )
            )
        }

        try await store.interruptActiveTasks()
        let recovered = try await store.loadPersistedTasks()

        XCTAssertEqual(recovered.map(\.record.status), [.interrupted, .interrupted])
        XCTAssertEqual(
            recovered.map(\.record.reasonCode),
            [.recoveryInterrupted, .recoveryInterrupted]
        )
        XCTAssertTrue(recovered.allSatisfy { $0.record.finishedAt != nil })
    }

    private func makeDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBTaskStoreTests-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private static func insertArtifact(_ id: UUID, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO artifact_records (
                    artifact_id, record_version, schema_id, state, relative_path,
                    media_type, byte_count, sha256, staged_at, finished_at,
                    reconciliation_state
                ) VALUES (?, 1, 'mediaAnalysis.v1', 'committed', 'result.json',
                    'application/json', 2, ?, 1, 2, 'stable')
                """,
            arguments: [id.uuidString, String(repeating: "a", count: 64)]
        )
    }
}

private actor ExecutionCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
