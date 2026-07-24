import Foundation

public struct TransferCopyTaskHandler: Sendable {
    public static let handlerID = DurableTaskHandlerID.transferCopy.rawValue
    public static let payloadVersion = 1

    private let fileSources: FileSourceRegistry
    private let coordinator: TransferCoordinator

    public init(
        fileSources: FileSourceRegistry,
        coordinator: TransferCoordinator = TransferCoordinator()
    ) {
        self.fileSources = fileSources
        self.coordinator = coordinator
    }

    public var taskHandler: TaskHandler {
        TaskHandler(handlerID: Self.handlerID, payloadVersion: Self.payloadVersion) {
            descriptor,
            events in
            let envelope = try TransferTaskEnvelope.decode(from: descriptor)
            let operations = try await fileSources.rebuildTransferOperations(for: envelope)
            let request = TransferRequest(
                taskID: descriptor.taskID,
                operation: .copy,
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
                summary: "Copied \(envelope.entries.count) item(s)",
                clipboard: nil
            )
        }
    }
}
