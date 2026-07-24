import Foundation
import XCTest
@testable import OpenFinderCore

final class TransferMoveRecoveryTests: XCTestCase {
    func testQueuedMoveClassifierAllowsNeverStarted() {
        // Given
        let descriptor = makeMoveDescriptor()

        // When
        let disposition = TransferMoveRecoveryClassifier.classify(
            descriptor: descriptor,
            persistedStatus: .queued,
            startedAt: nil
        )

        // Then
        XCTAssertEqual(disposition, .executableQueued)
    }

    func testStartedMoveNeverAutoResumes() async throws {
        // Given
        let accountID = UUID(uuidString: "14141414-1414-1414-1414-141414141414")!
        let remote = FakeMoveRemoteProvider()
        let original = Data("started-move-source".utf8)
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
        let taskID = UUID(uuidString: "15151515-1515-1515-1515-151515151515")!
        let descriptor = try makeRemoteDescriptor(
            accountID: accountID,
            entry: entry,
            destination: "/destination",
            taskID: taskID
        )
        let startedAt = Date(timeIntervalSince1970: 1_735_689_600)
        let resolutions = ProviderResolutionCounter()
        let remoteProviders = RemoteProviderRegistry { _, _ in
            await resolutions.increment()
            return remote
        }
        let fileSources = FileSourceRegistry(remoteProviderRegistry: remoteProviders)
        let handlers = TaskHandlerRegistry()
        try await handlers.register(
            TransferMoveTaskHandler(fileSources: fileSources).taskHandler
        )
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: handlers)

        // When
        let dispositions = [
            TransferMoveRecoveryClassifier.classify(
                descriptor: descriptor,
                persistedStatus: .running,
                startedAt: startedAt
            ),
            TransferMoveRecoveryClassifier.classify(
                descriptor: descriptor,
                persistedStatus: .cancelling,
                startedAt: startedAt
            ),
            TransferMoveRecoveryClassifier.classify(
                descriptor: descriptor,
                persistedStatus: .queued,
                startedAt: startedAt
            )
        ]
        let recoveredID = try await queue.recoverPersistedTask(
            .init(kind: .webDAVOperation, title: "Recovered started move"),
            descriptorData: JSONEncoder().encode(descriptor),
            persisted: .init(status: .running, startedAt: startedAt)
        )
        let recoveredRecord = await queue.record(for: recoveredID)
        let record = try XCTUnwrap(recoveredRecord)
        let resolutionCount = await resolutions.value

        // Then
        XCTAssertEqual(
            dispositions,
            Array(repeating: .interruptedRequiresIntervention, count: 3)
        )
        XCTAssertEqual(record.status, .interrupted)
        XCTAssertEqual(record.reasonCode, .recoveryInterrupted)
        XCTAssertEqual(resolutionCount, 0)
        let observables = await remote.observables()
        XCTAssertEqual(observables.moveCount, 0)
        XCTAssertEqual(observables.deleteCount, 0)
        XCTAssertEqual(observables.downloadCount, 0)
        XCTAssertEqual(observables.uploadCount, 0)
        XCTAssertEqual(observables.files["/source/item.txt"], original)
        XCTAssertNil(observables.files["/destination/item.txt"])
    }

    private func makeMoveDescriptor() -> TaskDescriptorEnvelope {
        let taskID = UUID(uuidString: "13131313-1313-1313-1313-131313131313")!
        return TaskDescriptorEnvelope(
            taskID: taskID,
            handlerID: DurableTaskHandlerID.transferMove.rawValue,
            payloadVersion: 1,
            resourceKey: "move:fixture",
            idempotencyKey: "move:fixture",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: 1
        )
    }
}

private actor ProviderResolutionCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
