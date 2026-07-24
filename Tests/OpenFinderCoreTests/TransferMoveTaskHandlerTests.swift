import Foundation
import XCTest
@testable import OpenFinderCore

final class TransferMoveTaskHandlerTests: XCTestCase {
    func testQueuedMoveCanStartAfterRecovery() async throws {
        // Given
        let fixture = try MoveHandlerFixture()
        defer { fixture.cleanup() }
        let provider = LocalFileProvider()
        let entry = TransferEntrySnapshot(
            try await provider.stat(.local(path: fixture.sourceFile.path))
        )
        let taskID = UUID(uuidString: "23232323-2323-2323-2323-232323232323")!
        let envelope = TransferTaskEnvelope(
            entries: [entry],
            source: .local(path: fixture.source.path),
            destination: .local(path: fixture.destination.path),
            overwrite: .rejectExisting
        )
        let descriptor = try envelope.makeDescriptor(
            taskID: taskID,
            handlerID: .transferMove,
            resourceKey: "move:local",
            idempotencyKey: "move:local",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: 1
        )
        XCTAssertEqual(
            TransferMoveRecoveryClassifier.classify(
                descriptor: descriptor,
                persistedStatus: .queued,
                startedAt: nil
            ),
            .executableQueued
        )
        let fileSources = FileSourceRegistry(
            localProvider: provider,
            remoteProviderRegistry: RemoteProviderRegistry { accountID, revision in
                throw RemoteProviderRegistry.UnsupportedProviderError(
                    accountID: accountID,
                    revision: revision
                )
            }
        )
        let registry = TaskHandlerRegistry()
        try await registry.register(
            TransferMoveTaskHandler(fileSources: fileSources).taskHandler
        )
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry)
        let descriptorData = try JSONEncoder().encode(descriptor)

        // When
        let queuedID = try await queue.recoverPersistedTask(
            .init(kind: .localMove, title: "Recovered durable local move"),
            descriptorData: descriptorData,
            persisted: .init(status: .queued, startedAt: nil)
        )
        let terminal = try await queue.waitForTerminalStatus(queuedID, timeout: 2)

        // Then
        XCTAssertEqual(terminal.status, .succeeded)
        XCTAssertEqual(terminal.resultSummary, "Moved 1 item(s)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceFile.path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationFile),
            Data("original".utf8)
        )
    }

    func testSameAccountRemoteMoveUsesProviderMoveWithoutDelete() async throws {
        // Given
        let accountID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!
        let remote = FakeMoveRemoteProvider()
        let original = Data("remote-original".utf8)
        await remote.store(
            original,
            at: "/source/item.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        let entry = await remoteEntry(
            accountID: accountID,
            path: "/source/item.txt",
            provider: remote
        )
        let queue = try await makeRemoteQueue(provider: remote)
        let descriptor = try makeRemoteDescriptor(
            accountID: accountID,
            entry: entry,
            destination: "/destination",
            taskID: UUID(uuidString: "45454545-4545-4545-4545-454545454545")!
        )

        // When
        let taskID = try await queue.enqueue(.init(
            kind: .webDAVOperation,
            title: "Same-account move",
            descriptor: descriptor
        ))
        let terminal = try await queue.waitForTerminalStatus(taskID, timeout: 2)

        // Then
        XCTAssertEqual(terminal.status, .succeeded)
        let observables = await remote.observables()
        XCTAssertEqual(observables.moveCount, 1)
        XCTAssertEqual(observables.deleteCount, 0)
        XCTAssertNil(observables.files["/source/item.txt"])
        XCTAssertEqual(observables.files["/destination/item.txt"], original)
    }

}
