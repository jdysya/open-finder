import Foundation

public enum TransferMoveRecoveryDisposition: Equatable, Sendable {
    case executableQueued
    case interruptedRequiresIntervention
}

public enum TransferMoveRecoveryClassifier {
    public static func classify(
        descriptor: TaskDescriptorEnvelope,
        persistedStatus: TaskStatus,
        startedAt: Date?
    ) -> TransferMoveRecoveryDisposition {
        guard descriptor.handlerID == DurableTaskHandlerID.transferMove.rawValue,
              descriptor.payloadVersion == 1,
              persistedStatus == .queued,
              startedAt == nil
        else {
            return .interruptedRequiresIntervention
        }
        return .executableQueued
    }
}

public struct TransferMoveTaskHandler: Sendable {
    public static let handlerID = DurableTaskHandlerID.transferMove.rawValue
    public static let payloadVersion = 1

    private let coordinator: TransferCoordinator
    private let fileSources: FileSourceRegistry

    public init(
        fileSources: FileSourceRegistry,
        coordinator: TransferCoordinator = TransferCoordinator()
    ) {
        self.coordinator = coordinator
        self.fileSources = fileSources
    }

    public var taskHandler: TaskHandler {
        TaskHandler(handlerID: Self.handlerID, payloadVersion: Self.payloadVersion) {
            descriptor,
            events in
            let envelope = try TransferTaskEnvelope.decode(from: descriptor)
            let operations = try await fileSources.rebuildTransferOperations(for: envelope)
            let request = TransferRequest(
                taskID: descriptor.taskID,
                operation: .move,
                entries: envelope.entries,
                source: envelope.source,
                destination: envelope.destination,
                overwrite: envelope.overwrite,
                destinationSnapshots: envelope.destinationSnapshots
            )
            try await coordinator.execute(
                request,
                operations: operations,
                progress: { snapshot in
                    await events.updateProgress(snapshot)
                },
                beforeEffects: {
                    try await events.markEffectsCommitted()
                }
            )
            return .success(
                summary: "Moved \(envelope.entries.count) item(s)",
                clipboard: nil
            )
        }
    }
}
