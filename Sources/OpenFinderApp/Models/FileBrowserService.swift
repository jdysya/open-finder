import Foundation
import OpenFinderCore

struct FileBrowserService: Sendable {
    let fileSourceRegistry: FileSourceRegistry
    private let taskService: TaskApplicationService?

    init(
        fileSourceRegistry: FileSourceRegistry,
        taskService: TaskApplicationService? = nil
    ) {
        self.fileSourceRegistry = fileSourceRegistry
        self.taskService = taskService
    }

    func listing(
        at location: Location,
        showHiddenFiles: Bool,
        revision: String
    ) async throws -> BrowserPaneListing {
        let source = try await fileSourceRegistry.resolve(location, revision: revision)
        let listing = try await source.list(options: .init(
            showHiddenFiles: showHiddenFiles,
            sort: .name(ascending: true)
        ))
        return .init(
            locationCapabilities: source.capabilities,
            listingCapabilities: listing.capabilities,
            providerRevision: listing.providerRevision == "local"
                ? revision
                : listing.providerRevision,
            items: Self.sortItems(listing.items),
            parentLocation: listing.parent
        )
    }

    func normalizedLocation(_ location: Location) throws -> Location {
        try fileSourceRegistry.normalizedLocation(location)
    }

    func resolve(_ location: Location, revision: String) async throws -> ResolvedFileSource {
        try await fileSourceRegistry.resolve(location, revision: revision)
    }

    func materialize(
        _ location: Location,
        revision: String
    ) async throws -> MaterializationLease {
        try await fileSourceRegistry.materialize(location, revision: revision)
    }

    func submitTransfer(
        _ items: [FileItem],
        source: Location,
        destination: Location,
        move: Bool,
        overwriteExisting: Bool,
        title: String
    ) async throws -> UUID {
        guard let taskService else {
            throw AppDurableHandlerCompositionError.missingTaskHandler(.init(
                handlerID: DurableTaskHandlerID.transferCopy.rawValue,
                payloadVersion: 1
            ))
        }
        try await taskService.requireReadiness()
        let taskID = UUID()
        let handlerID: DurableTaskHandlerID = move ? .transferMove : .transferCopy
        let envelope = try await fileSourceRegistry.makeTransferEnvelope(
            items: items,
            source: source,
            destination: destination,
            overwrite: overwriteExisting ? .replaceExisting : .rejectExisting
        )
        let descriptor = try await envelope.makeDescriptor(
            taskID: taskID,
            handlerID: handlerID,
            resourceKey: "transfer:\(destination.displayPath)",
            idempotencyKey: envelope.idempotencyKey(for: handlerID),
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: taskService.reserveQueueOrdinal()
        )
        return try await taskService.enqueue(.init(
            kind: move ? .localMove : .localCopy,
            title: title,
            descriptor: descriptor
        ))
    }

    private static func sortItems(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
