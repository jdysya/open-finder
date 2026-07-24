import Foundation
import OpenFinderCore

enum FileTransferService {
    private static let transferCoordinator = TransferCoordinator()

    static func copyOrMove(
        _ items: [FileItem],
        from source: Location,
        to destination: Location,
        move: Bool,
        overwriteExisting: Bool = false,
        taskID: TaskID = UUID(),
        faultPoint: TransferCoordinator.FaultPoint? = nil,
        remoteProviderResolver: @escaping @Sendable (RemoteLocation) async throws -> any RemoteProvider,
        progress: (@Sendable (Double, String) async -> Void)? = nil
    ) async throws {
        let remoteLocations = ([source, destination] + items.map(\.location))
            .compactMap(remoteLocation)
        let fileSources = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { accountID, revision in
                guard let resolvedAccountID = UUID(uuidString: accountID),
                      let location = remoteLocations.first(where: {
                          $0.accountID == resolvedAccountID
                      })
                else {
                    throw RemoteProviderRegistry.UnsupportedProviderError(
                        accountID: accountID,
                        revision: revision
                    )
                }
                return try await remoteProviderResolver(location)
            }
        )
        let envelope = try await fileSources.makeTransferEnvelope(
            items: items,
            source: source,
            destination: destination,
            overwrite: overwriteExisting ? .replaceExisting : .rejectExisting
        )
        let request = TransferRequest(
            taskID: taskID,
            operation: move ? .move : .copy,
            entries: envelope.entries,
            source: source,
            destination: destination,
            overwrite: envelope.overwrite,
            destinationSnapshots: envelope.destinationSnapshots
        )
        let operations = try await fileSources.rebuildTransferOperations(for: envelope)
        try await transferCoordinator.execute(
            request,
            operations: operations,
            progress: { snapshot in
                await progress?(snapshot.fraction, snapshot.detail ?? "Transferring")
            },
            faultPoint: faultPoint
        )
    }

    private static func remoteLocation(_ location: Location) -> RemoteLocation? {
        switch location {
        case .remote(let remoteLocation):
            remoteLocation
        case .webDAV(let accountID, let path):
            .init(
                accountID: accountID,
                connectorID: .webDAV,
                path: .init(identifier: path, displayPath: path)
            )
        case .local, .rclone:
            nil
        }
    }
}
