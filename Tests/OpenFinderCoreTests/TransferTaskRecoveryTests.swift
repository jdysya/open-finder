import Foundation
import XCTest
@testable import OpenFinderCore

final class TransferTaskRecoveryTests: XCTestCase {
    func testRunningAndCancellingPersistedCopiesRestoreInterruptedWithoutEffects() async throws {
        for status in [TaskStatus.running, .cancelling] {
            // Given
            let fixture = try TransferRecoveryFixture(label: status.rawValue)
            defer { fixture.cleanup() }
            let descriptor = try await fixture.makeDescriptor()
            let (queue, executionCount) = try await fixture.makeQueue()

            // When
            let taskID = try await queue.recoverPersistedTask(
                .init(kind: .localCopy, title: "Recovered \(status.rawValue) copy"),
                descriptorData: JSONEncoder().encode(descriptor),
                persisted: .init(status: status, startedAt: nil)
            )
            let record = try await queue.waitForTerminalStatus(taskID, timeout: 2)
            let repeatedTaskID = try await queue.recoverPersistedTask(
                .init(kind: .localCopy, title: "Repeated \(status.rawValue) recovery"),
                descriptorData: JSONEncoder().encode(descriptor),
                persisted: .init(status: status, startedAt: nil)
            )
            let repeatedRecord = try await queue.waitForTerminalStatus(
                repeatedTaskID,
                timeout: 2
            )
            let effects = await executionCount.value

            // Then
            XCTAssertEqual(record.status, .interrupted)
            XCTAssertEqual(record.reasonCode, .recoveryInterrupted)
            XCTAssertEqual(repeatedTaskID, taskID)
            XCTAssertEqual(repeatedRecord.status, .interrupted)
            XCTAssertEqual(repeatedRecord.reasonCode, .recoveryInterrupted)
            XCTAssertEqual(effects, 0)
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.destination.path
                ).isEmpty
            )
        }
    }

    func testQueuedPersistedCopyWithStartedAtInterruptsThenRetryRepreflights() async throws {
        // Given
        let fixture = try TransferRecoveryFixture(label: "queued-started")
        defer { fixture.cleanup() }
        let descriptor = try await fixture.makeDescriptor()
        let (queue, executionCount) = try await fixture.makeQueue()
        let startedAt = Date(timeIntervalSince1970: 1_735_689_600)

        // When
        let recoveredID = try await queue.recoverPersistedTask(
            .init(kind: .localCopy, title: "Recovered started copy"),
            descriptorData: JSONEncoder().encode(descriptor),
            persisted: .init(status: .queued, startedAt: startedAt)
        )
        let interrupted = try await queue.waitForTerminalStatus(recoveredID, timeout: 2)
        let effectsBeforeRetry = await executionCount.value

        // Then
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertEqual(interrupted.startedAt, startedAt)
        XCTAssertEqual(effectsBeforeRetry, 0)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.destination.path
            ).isEmpty
        )

        // When
        try Data("changed after interruption".utf8).write(to: fixture.destinationFile)
        let retryID = try await queue.retry(recoveredID)
        let retry = try await queue.waitForTerminalStatus(retryID, timeout: 2)
        let effectsAfterRetry = await executionCount.value

        // Then
        XCTAssertEqual(retry.status, .failed)
        XCTAssertTrue(retry.errorMessage?.contains("destinationConflict") == true)
        XCTAssertEqual(effectsAfterRetry, 1)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationFile),
            Data("changed after interruption".utf8)
        )
        print(
            "STARTED_COPY_RECOVERY recovered=\(interrupted.status.rawValue) " +
            "effectsBeforeRetry=0 retry=\(retry.status.rawValue) overwrite=false"
        )
    }
}

private struct TransferRecoveryFixture {
    let root: URL
    let source: URL
    let destination: URL
    let sourceFile: URL
    let destinationFile: URL

    init(label: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OpenFinderTransferRecovery-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        sourceFile = source.appendingPathComponent("item.txt")
        destinationFile = destination.appendingPathComponent("item.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try Data("source bytes".utf8).write(to: sourceFile)
    }

    func makeDescriptor() async throws -> TaskDescriptorEnvelope {
        let provider = LocalFileProvider()
        let entry = TransferEntrySnapshot(
            try await provider.stat(.local(path: sourceFile.path))
        )
        let taskID = UUID()
        return try TransferTaskEnvelope(
            entries: [entry],
            source: .local(path: source.path),
            destination: .local(path: destination.path),
            overwrite: .rejectExisting
        ).makeDescriptor(
            taskID: taskID,
            handlerID: .transferCopy,
            resourceKey: "copy:\(destination.path)",
            idempotencyKey: "copy:\(taskID.uuidString)",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: 1
        )
    }

    func makeQueue() async throws -> (TaskQueueService, RecoveryExecutionCount) {
        let fileSources = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { accountID, revision in
                throw RemoteProviderRegistry.UnsupportedProviderError(
                    accountID: accountID,
                    revision: revision
                )
            }
        )
        let count = RecoveryExecutionCount()
        let copy = TransferCopyTaskHandler(fileSources: fileSources).taskHandler
        let handlers = TaskHandlerRegistry()
        try await handlers.register(TaskHandler(
            handlerID: copy.handlerID,
            payloadVersion: copy.payloadVersion
        ) { descriptor, events in
            await count.increment()
            return try await copy.execute(descriptor: descriptor, events: events)
        })
        return (
            TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: handlers),
            count
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RecoveryExecutionCount {
    private var count = 0
    var value: Int { count }
    func increment() { count += 1 }
}
