import Foundation
import XCTest
@testable import OpenFinderCore

final class TransferMoveRecoveryTests: XCTestCase {
    func testNeverStartedQueuedMoveIsExecutableOnRecovery() {
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

    func testStartedMoveNeverAutoResumesOnRecovery() {
        // Given
        let descriptor = makeMoveDescriptor()
        let startedAt = Date(timeIntervalSince1970: 1_735_689_600)

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

        // Then
        XCTAssertEqual(
            dispositions,
            Array(repeating: .interruptedRequiresIntervention, count: 3)
        )
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
