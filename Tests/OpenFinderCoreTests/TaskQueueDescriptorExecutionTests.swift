import Foundation
import XCTest
@testable import OpenFinderCore

final class TaskQueueDescriptorExecutionTests: XCTestCase {
    func testDescriptorExecutionPersistsOrderedProgressLogsAndTerminalState() async throws {
        let store = RecordingTaskStore()
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
            await events.appendLog("after progress")
            try await events.markEffectsCommitted()
            return .success(summary: "copied", clipboard: nil)
        })
        let queue = TaskQueueService(
            maxConcurrentTasks: 1,
            handlerRegistry: registry,
            store: store
        )
        let descriptor = makeDescriptor(ordinal: 10)

        let id = try await queue.enqueue(.init(
            kind: .localCopy,
            title: "Durable copy",
            descriptor: descriptor
        ))
        let terminal = try await queue.waitForTerminalStatus(id, timeout: 2)
        let events = await store.events

        XCTAssertEqual(terminal.status, .succeeded)
        XCTAssertEqual(terminal.resultSummary, "copied")
        XCTAssertEqual(events.first, .enqueue(id))
        XCTAssertTrue(events.contains(.record(id, .running, false)))
        XCTAssertEqual(
            events.filter(\.isLog).map(\.message),
            ["copy: half", "after progress"]
        )
        XCTAssertEqual(events.last, .record(id, .succeeded, true))
    }

    func testResourceLockSkipsBlockedDescriptorWithoutBreakingMatchingFIFO() async throws {
        let registry = TaskHandlerRegistry()
        let gate = DescriptorGate()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ) { descriptor, _ in
            await gate.enter(descriptor.taskID)
            return .success(summary: "done", clipboard: nil)
        })
        let queue = TaskQueueService(maxConcurrentTasks: 2, handlerRegistry: registry)
        let first = makeDescriptor(resourceKey: "shared", ordinal: 1)
        let second = makeDescriptor(resourceKey: "shared", ordinal: 2)
        let unrelated = makeDescriptor(resourceKey: "other", ordinal: 3)

        let firstID = try await queue.enqueue(.init(kind: .localCopy, title: "first", descriptor: first))
        await gate.waitForEntries(1)
        let secondID = try await queue.enqueue(.init(kind: .localCopy, title: "second", descriptor: second))
        let unrelatedID = try await queue.enqueue(.init(kind: .localCopy, title: "other", descriptor: unrelated))
        await gate.waitForEntries(2)

        let firstEntries = await gate.entries
        let queuedStatus = await queue.record(for: secondID)?.status
        XCTAssertEqual(firstEntries, [firstID, unrelatedID])
        XCTAssertEqual(queuedStatus, .queued)
        await gate.release(firstID)
        _ = try await queue.waitForTerminalStatus(firstID, timeout: 2)
        await gate.waitForEntries(3)
        let allEntries = await gate.entries
        XCTAssertEqual(allEntries, [firstID, unrelatedID, secondID])
        await gate.release(unrelatedID)
        await gate.release(secondID)
        _ = try await queue.waitForTerminalStatus(unrelatedID, timeout: 2)
        _ = try await queue.waitForTerminalStatus(secondID, timeout: 2)
    }

    func testCancellationWindowsPersistBeforeCommitButIgnoreAfterCommit() async throws {
        let store = RecordingTaskStore()
        let registry = TaskHandlerRegistry()
        let beforeCommit = DescriptorGate()
        let afterCommit = DescriptorGate()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ) { descriptor, events in
            if descriptor.redactedPayload["window"] == "before" {
                await beforeCommit.enter(descriptor.taskID)
                try await events.markEffectsCommitted()
                return .success(summary: "unexpected", clipboard: nil)
            }
            try await events.markEffectsCommitted()
            await afterCommit.enter(descriptor.taskID)
            return .success(summary: "committed", clipboard: nil)
        })
        let queue = TaskQueueService(
            maxConcurrentTasks: 2,
            handlerRegistry: registry,
            store: store
        )
        let before = makeDescriptor(resourceKey: "before", ordinal: 1, payload: ["window": "before"])
        let after = makeDescriptor(resourceKey: "after", ordinal: 2, payload: ["window": "after"])

        let beforeID = try await queue.enqueue(.init(kind: .localCopy, title: "before", descriptor: before))
        let afterID = try await queue.enqueue(.init(kind: .localCopy, title: "after", descriptor: after))
        await beforeCommit.waitForEntries(1)
        await afterCommit.waitForEntries(1)
        await queue.cancel(beforeID)
        await queue.cancel(afterID)
        await beforeCommit.release(beforeID)
        await afterCommit.release(afterID)

        let beforeTerminal = try await queue.waitForTerminalStatus(beforeID, timeout: 2)
        let afterTerminal = try await queue.waitForTerminalStatus(afterID, timeout: 2)
        let persistedEvents = await store.events
        XCTAssertEqual(beforeTerminal.status, .cancelled)
        XCTAssertEqual(afterTerminal.status, .succeeded)
        XCTAssertTrue(persistedEvents.contains(.record(beforeID, .cancelled, false)))
        XCTAssertTrue(persistedEvents.contains(.record(afterID, .succeeded, true)))
    }

    func testRetryCreatesImmutableLineageAndIndependentLogs() async throws {
        let store = RecordingTaskStore()
        let registry = TaskHandlerRegistry()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ) { descriptor, events in
            await events.appendLog("attempt \(descriptor.lineage.attempt)")
            return .success(summary: "attempt \(descriptor.lineage.attempt)", clipboard: nil)
        })
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry, store: store)
        let descriptor = makeDescriptor(ordinal: 41)
        let firstID = try await queue.enqueue(.init(kind: .localCopy, title: "first", descriptor: descriptor))
        let firstTerminal = try await queue.waitForTerminalStatus(firstID, timeout: 2)

        let retryID = try await queue.retry(firstID)
        let retryTerminal = try await queue.waitForTerminalStatus(retryID, timeout: 2)
        let originalAfterRetry = await queue.record(for: firstID)
        let firstLogs = await queue.logs(for: firstID).map(\.message)
        let retryLogs = await queue.logs(for: retryID).map(\.message)
        let enqueuedIDs = await store.enqueuedIDs

        XCTAssertNotEqual(retryID, firstID)
        XCTAssertEqual(originalAfterRetry, firstTerminal)
        XCTAssertEqual(retryTerminal.descriptor?.lineage.rootTaskID, firstID)
        XCTAssertEqual(retryTerminal.descriptor?.lineage.parentTaskID, firstID)
        XCTAssertEqual(retryTerminal.descriptor?.lineage.attempt, 2)
        XCTAssertEqual(retryTerminal.descriptor?.queueOrdinal, 42)
        XCTAssertEqual(firstLogs, ["attempt 1"])
        XCTAssertEqual(retryLogs, ["attempt 2"])
        XCTAssertEqual(enqueuedIDs, [firstID, retryID])
    }

    func testEphemeralRequestIsNeverMarkedDurable() async throws {
        let store = RecordingTaskStore()
        let descriptor = makeDescriptor(ordinal: 1)
        let queue = TaskQueueService(maxConcurrentTasks: 1, store: store)

        let id = try await queue.enqueue(.init(
            kind: .localCopy,
            title: "Explicit ephemeral compatibility request",
            descriptor: descriptor
        ) { context in
            await context.appendLog("memory only")
            return .success(summary: "ephemeral", clipboard: nil)
        })
        let terminal = try await queue.waitForTerminalStatus(id, timeout: 2)
        let storeEvents = await store.events

        XCTAssertEqual(terminal.status, .succeeded)
        XCTAssertEqual(terminal.resultSummary, "ephemeral")
        XCTAssertTrue(storeEvents.isEmpty)
    }

    func testRecoveryUsesOnlyDurableDescriptorAndNeverRecoversOperation() async throws {
        let store = RecordingTaskStore()
        let operationCounter = DescriptorExecutionCounter()
        let registry = TaskHandlerRegistry()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ) { _, _ in
            await operationCounter.incrementHandler()
            return .success(summary: "durable handler", clipboard: nil)
        })
        let descriptor = makeDescriptor(ordinal: 7)
        let queue = TaskQueueService(
            maxConcurrentTasks: 1,
            handlerRegistry: registry,
            store: store
        )

        let id = try await queue.recoverPersistedTask(
            .init(
                kind: .localCopy,
                title: "Recovered descriptor",
                operation: { _ in
                    await operationCounter.incrementOperation()
                    return .success(summary: "ephemeral operation", clipboard: nil)
                }
            ),
            descriptorData: JSONEncoder().encode(descriptor)
        )
        let terminal = try await queue.waitForTerminalStatus(id, timeout: 2)
        let counts = await operationCounter.values
        let enqueuedIDs = await store.enqueuedIDs

        XCTAssertEqual(terminal.status, .succeeded)
        XCTAssertEqual(terminal.resultSummary, "durable handler")
        XCTAssertEqual(counts.handler, 1)
        XCTAssertEqual(counts.operation, 0)
        XCTAssertTrue(enqueuedIDs.isEmpty)
    }

    private func makeDescriptor(
        resourceKey: String? = nil,
        ordinal: UInt64,
        payload: [String: String] = [:]
    ) -> TaskDescriptorEnvelope {
        let id = UUID()
        return TaskDescriptorEnvelope(
            taskID: id,
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1,
            resourceKey: resourceKey,
            lineage: .init(rootTaskID: id),
            queueOrdinal: ordinal,
            redactedPayload: payload
        )
    }
}

private enum RecordedTaskStoreEvent: Equatable {
    case enqueue(UUID)
    case record(UUID, TaskStatus, Bool)
    case log(UUID, String)

    var isLog: Bool {
        if case .log = self { true } else { false }
    }

    var message: String {
        if case .log(_, let message) = self { message } else { "" }
    }
}

private actor RecordingTaskStore: TaskStore {
    private(set) var events: [RecordedTaskStoreEvent] = []

    var enqueuedIDs: [UUID] {
        events.compactMap {
            if case .enqueue(let id) = $0 { id } else { nil }
        }
    }

    func enqueue(descriptor: TaskDescriptorEnvelope, record: TaskRecord) async throws {
        XCTAssertEqual(descriptor, record.descriptor)
        events.append(.enqueue(record.id))
    }

    func update(record: TaskRecord, effectsCommitted: Bool) async throws {
        events.append(.record(record.id, record.status, effectsCommitted))
    }

    func append(log: TaskLogLine) async throws {
        events.append(.log(log.taskID, log.message))
    }
}

private actor DescriptorGate {
    private(set) var entries: [UUID] = []
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func enter(_ id: UUID) async {
        entries.append(id)
        let ready = entryWaiters.filter { entries.count >= $0.0 }
        entryWaiters.removeAll { entries.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { continuations[id] = $0 }
    }

    func waitForEntries(_ count: Int) async {
        guard entries.count < count else { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    func release(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume()
    }
}

private actor DescriptorExecutionCounter {
    private var handlerCount = 0
    private var operationCount = 0

    var values: (handler: Int, operation: Int) {
        (handlerCount, operationCount)
    }

    func incrementHandler() {
        handlerCount += 1
    }

    func incrementOperation() {
        operationCount += 1
    }
}
