import Foundation
import XCTest
@testable import OpenFinderCore

final class DurableTaskRetryTests: XCTestCase {
    func testRetryCreatesLinkedImmutableAttempt() async throws {
        // Given
        let registry = TaskHandlerRegistry()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.pluginExecute.rawValue,
            payloadVersion: 1
        ) { descriptor, _ in
            .success(summary: "attempt \(descriptor.lineage.attempt)", clipboard: nil)
        })
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry)
        let originalID = UUID()
        let originalDescriptor = TaskDescriptorEnvelope(
            taskID: originalID,
            handlerID: DurableTaskHandlerID.pluginExecute.rawValue,
            payloadVersion: 1,
            resourceKey: "plugin:fixture:inspect",
            idempotencyKey: "plugin:fixture:inspect:config-v1",
            lineage: .init(rootTaskID: originalID),
            queueOrdinal: 1,
            redactedPayload: ["configuration": "{\"mode\":\"v1\"}"]
        )
        let firstID = try await queue.enqueue(.init(
            kind: .plugin(pluginID: "fixture", actionID: "inspect"),
            title: "Inspect fixture",
            descriptor: originalDescriptor
        ))
        _ = try await queue.waitForTerminalStatus(firstID, timeout: 2)

        // When
        let retryID = try await queue.retry(firstID)
        let retry = try await queue.waitForTerminalStatus(retryID, timeout: 2)
        let originalRecord = await queue.record(for: firstID)
        let original = try XCTUnwrap(originalRecord)

        // Then
        XCTAssertNotEqual(retryID, firstID)
        XCTAssertEqual(original.descriptor, originalDescriptor)
        XCTAssertEqual(retry.descriptor?.lineage.rootTaskID, firstID)
        XCTAssertEqual(retry.descriptor?.lineage.parentTaskID, firstID)
        XCTAssertEqual(retry.descriptor?.lineage.attempt, 2)
        XCTAssertEqual(retry.descriptor?.redactedPayload, originalDescriptor.redactedPayload)
    }

    func testActiveDuplicateEnqueueReusesExistingAttempt() async throws {
        // Given
        let gate = RetryAttemptGate()
        let registry = TaskHandlerRegistry()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.pluginExecute.rawValue,
            payloadVersion: 1
        ) { descriptor, _ in
            await gate.enter(descriptor.taskID)
            await gate.waitForRelease()
            return .success(summary: "done", clipboard: nil)
        })
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry)
        let first = makeDescriptor(taskID: UUID(), ordinal: 1)
        let duplicate = makeDescriptor(taskID: UUID(), ordinal: 2)
        let firstID = try await queue.enqueue(.init(
            kind: .plugin(pluginID: "fixture", actionID: "inspect"),
            title: "Inspect fixture",
            descriptor: first
        ))
        await gate.waitForEntry()

        // When
        let duplicateID = try await queue.enqueue(.init(
            kind: .plugin(pluginID: "fixture", actionID: "inspect"),
            title: "Inspect fixture",
            descriptor: duplicate
        ))

        // Then
        XCTAssertEqual(duplicateID, firstID)
        let history = await queue.history()
        XCTAssertEqual(history.count, 1)
        await gate.release()
        _ = try await queue.waitForTerminalStatus(firstID, timeout: 2)
    }

    func testRepeatedRetryReusesActiveRetryAttempt() async throws {
        // Given
        let gate = RetryAttemptGate()
        let registry = TaskHandlerRegistry()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.pluginExecute.rawValue,
            payloadVersion: 1
        ) { descriptor, _ in
            if descriptor.lineage.attempt == 2 {
                await gate.enter(descriptor.taskID)
                await gate.waitForRelease()
            }
            return .success(summary: "attempt \(descriptor.lineage.attempt)", clipboard: nil)
        })
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry)
        let first = makeDescriptor(taskID: UUID(), ordinal: 1)
        let firstID = try await queue.enqueue(.init(
            kind: .plugin(pluginID: "fixture", actionID: "inspect"),
            title: "Inspect fixture",
            descriptor: first
        ))
        _ = try await queue.waitForTerminalStatus(firstID, timeout: 2)
        let retryID = try await queue.retry(firstID)
        await gate.waitForEntry()

        // When
        let repeatedRetryID = try await queue.retry(firstID)

        // Then
        XCTAssertEqual(repeatedRetryID, retryID)
        let history = await queue.history()
        XCTAssertEqual(history.count, 2)
        await gate.release()
        _ = try await queue.waitForTerminalStatus(retryID, timeout: 2)
    }

    func testPartialMoveRequiresUserIntervention() async throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderPartialMove-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let sourceFile = source.appendingPathComponent("item.txt")
        let movedFile = destination.appendingPathComponent("item.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("source bytes".utf8).write(to: sourceFile)
        let provider = LocalFileProvider()
        let entry = TransferEntrySnapshot(try await provider.stat(.local(path: sourceFile.path)))
        let firstID = UUID()
        let descriptor = try TransferTaskEnvelope(
            entries: [entry],
            source: .local(path: source.path),
            destination: .local(path: destination.path),
            overwrite: .rejectExisting
        ).makeDescriptor(
            taskID: firstID,
            handlerID: .transferMove,
            resourceKey: "move:\(destination.path)",
            idempotencyKey: "move:fixture",
            lineage: .init(rootTaskID: firstID),
            queueOrdinal: 1
        )
        try FileManager.default.moveItem(at: sourceFile, to: movedFile)
        let fileSources = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { accountID, revision in
                throw RemoteProviderRegistry.UnsupportedProviderError(
                    accountID: accountID,
                    revision: revision
                )
            }
        )
        let registry = TaskHandlerRegistry()
        try await registry.register(TransferMoveTaskHandler(fileSources: fileSources).taskHandler)
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry)

        // When
        let queuedID = try await queue.enqueue(.init(
            kind: .localMove,
            title: "Move item",
            descriptor: descriptor
        ))
        let record = try await queue.waitForTerminalStatus(queuedID, timeout: 2)

        // Then
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.reasonCode?.rawValue, "alreadyMoved")
        XCTAssertEqual(try Data(contentsOf: movedFile), Data("source bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    private func makeDescriptor(taskID: UUID, ordinal: UInt64) -> TaskDescriptorEnvelope {
        TaskDescriptorEnvelope(
            taskID: taskID,
            handlerID: DurableTaskHandlerID.pluginExecute.rawValue,
            payloadVersion: 1,
            resourceKey: "plugin:fixture:inspect",
            idempotencyKey: "plugin:fixture:inspect:config-v1",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: ordinal,
            redactedPayload: ["configuration": "{\"mode\":\"v1\"}"]
        )
    }
}

private actor RetryAttemptGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter(_: UUID) {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
    }

    func waitForEntry() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
