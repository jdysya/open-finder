import XCTest
@testable import OpenFinderCore

final class TaskExecutionIdentityTests: XCTestCase {
    func testContextIDMatchesRecordID() async throws {
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let ids = IDRecorder()

        let recordID = try await queue.enqueue(.init(kind: .plugin(pluginID: "fixture", actionID: "run"), title: "Run") { context in
            await ids.append(context.id)
            return .success(summary: "done", clipboard: nil)
        })

        _ = try await queue.waitForTerminalStatus(recordID, timeout: 2)
        let captured = await ids.values()
        let record = await queue.record(for: recordID)
        XCTAssertEqual(captured, [recordID])
        XCTAssertEqual(record?.id, recordID)
    }

    func testRetryUsesNewContextID() async throws {
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let ids = IDRecorder()
        let firstID = try await queue.enqueue(.init(kind: .plugin(pluginID: "fixture", actionID: "run"), title: "Run") { context in
            await ids.append(context.id)
            return .success(summary: "done", clipboard: nil)
        })
        _ = try await queue.waitForTerminalStatus(firstID, timeout: 2)

        let retryID = try await queue.retry(firstID)
        _ = try await queue.waitForTerminalStatus(retryID, timeout: 2)

        XCTAssertNotEqual(firstID, retryID)
        let captured = await ids.values()
        XCTAssertEqual(captured, [firstID, retryID])
    }

    func testRetryPreservesRootAndCreatesParentAttemptLineage() async throws {
        let rootID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let descriptor = TaskDescriptorEnvelope(
            taskID: rootID,
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1,
            resourceKey: "copy:source",
            idempotencyKey: "copy:request",
            lineage: .init(rootTaskID: rootID),
            queueOrdinal: 7,
            redactedPayload: ["displayName": "source.txt"]
        )
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let firstID = try await queue.enqueue(.init(
            kind: .localCopy,
            title: "Copy",
            descriptor: descriptor
        ) { _ in
            .success(summary: "done", clipboard: nil)
        })
        _ = try await queue.waitForTerminalStatus(firstID, timeout: 2)

        let retryID = try await queue.retry(firstID)
        let retried = try await queue.waitForTerminalStatus(retryID, timeout: 2)

        XCTAssertEqual(firstID, rootID)
        XCTAssertNotEqual(retryID, firstID)
        XCTAssertEqual(retried.descriptor?.taskID, retryID)
        XCTAssertEqual(retried.descriptor?.lineage.rootTaskID, rootID)
        XCTAssertEqual(retried.descriptor?.lineage.parentTaskID, firstID)
        XCTAssertEqual(retried.descriptor?.lineage.attempt, 2)
        XCTAssertEqual(retried.descriptor?.queueOrdinal, 8)
        XCTAssertEqual(retried.descriptor?.idempotencyKey, "copy:request")
    }
}

private actor IDRecorder {
    private var storage: [UUID] = []
    func append(_ id: UUID) { storage.append(id) }
    func values() -> [UUID] { storage }
}
