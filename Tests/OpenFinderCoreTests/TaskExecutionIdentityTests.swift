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
}

private actor IDRecorder {
    private var storage: [UUID] = []
    func append(_ id: UUID) { storage.append(id) }
    func values() -> [UUID] { storage }
}
