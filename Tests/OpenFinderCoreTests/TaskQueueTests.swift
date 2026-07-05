import Foundation
import XCTest
@testable import OpenFinderCore

final class TaskQueueTests: XCTestCase {
    func testRunsQueuedTaskAndStoresHistory() async throws {
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let id = try await queue.enqueue(.init(kind: .plugin(pluginID: "plugin", actionID: "action"), title: "Succeed") { context in
            await context.updateProgress(0.25, "Started")
            await context.appendLog("hello")
            return .success(summary: "done", clipboard: "copied")
        })

        let record = try await queue.waitForTerminalStatus(id, timeout: 2.0)

        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(record.progress, 1.0)
        XCTAssertEqual(record.resultSummary, "done")
        XCTAssertEqual(record.clipboardText, "copied")
        let messages = await queue.logs(for: id).map(\.message)
        let historyIDs = await queue.history().map(\.id)
        XCTAssertEqual(messages, ["Started", "hello"])
        XCTAssertEqual(historyIDs, [id])
    }

    func testRetriesFailedTaskWithSameRequest() async throws {
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let attempts = AttemptCounter()
        let firstID = try await queue.enqueue(.init(kind: .localCopy, title: "Flaky") { _ in
            let count = await attempts.increment()
            if count == 1 { throw OpenFinderError.operationFailed("first failure") }
            return .success(summary: "second ok", clipboard: nil)
        })
        let failed = try await queue.waitForTerminalStatus(firstID, timeout: 2.0)
        XCTAssertEqual(failed.status, .failed)

        let retryID = try await queue.retry(firstID)
        let retried = try await queue.waitForTerminalStatus(retryID, timeout: 2.0)

        XCTAssertNotEqual(firstID, retryID)
        XCTAssertEqual(retried.status, .succeeded)
        XCTAssertEqual(retried.retryCount, 1)
        let attemptCount = await attempts.value
        XCTAssertEqual(attemptCount, 2)
    }

    func testCancelsRunningTask() async throws {
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let id = try await queue.enqueue(.init(kind: .localMove, title: "Long") { context in
            while await !context.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        })

        try await Task.sleep(nanoseconds: 50_000_000)
        await queue.cancel(id)
        let record = try await queue.waitForTerminalStatus(id, timeout: 2.0)

        XCTAssertEqual(record.status, .cancelled)
    }

    @MainActor
    func testTaskQueueOperationCreatedOnMainActorRunsAwayFromMainThread() async throws {
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let id = try await queue.enqueue(.init(kind: .localCopy, title: "Thread check") { _ in
            XCTAssertFalse(Thread.isMainThread, "Task queue operations must not execute on the main thread")
            return .success(summary: "ok", clipboard: nil)
        })

        let record = try await queue.waitForTerminalStatus(id, timeout: 2.0)
        XCTAssertEqual(record.status, .succeeded)
    }

}

private actor AttemptCounter {
    private var count = 0

    var value: Int { count }

    func increment() -> Int {
        count += 1
        return count
    }
}
