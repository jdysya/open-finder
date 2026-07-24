import Foundation

public enum TransferOperation: String, Codable, Hashable, Sendable {
    case copy
    case move
}

public enum TransferOverwritePolicy: String, Codable, Hashable, Sendable {
    case rejectExisting
    case replaceExisting
}

public struct TransferEntrySnapshot: Codable, Hashable, Sendable {
    public let item: FileItem

    public init(_ item: FileItem) {
        self.item = item
    }

    public var id: String { item.id }
    public var name: String { item.name }
    public var location: Location { item.location }
    public var kind: FileKind { item.kind }

    func matches(_ current: TransferEntrySnapshot) -> Bool {
        item.id == current.item.id
            && item.name == current.item.name
            && item.location == current.item.location
            && item.kind == current.item.kind
            && item.size == current.item.size
            && item.modificationDate == current.item.modificationDate
    }

    func contentMatches(_ other: TransferEntrySnapshot) -> Bool {
        item.name == other.item.name
            && item.kind == other.item.kind
            && item.size == other.item.size
            && item.modificationDate == other.item.modificationDate
    }
}

public struct TransferRequest: Codable, Hashable, Sendable {
    public let taskID: TaskID
    public let operation: TransferOperation
    public let entries: [TransferEntrySnapshot]
    public let source: Location
    public let destination: Location
    public let overwrite: TransferOverwritePolicy
    public let destinationSnapshots: [TransferEntrySnapshot?]

    public init(
        taskID: TaskID,
        operation: TransferOperation,
        entries: [TransferEntrySnapshot],
        source: Location,
        destination: Location,
        overwrite: TransferOverwritePolicy,
        destinationSnapshots: [TransferEntrySnapshot?]? = nil
    ) {
        self.taskID = taskID
        self.operation = operation
        self.entries = entries
        self.source = source
        self.destination = destination
        self.overwrite = overwrite
        self.destinationSnapshots = destinationSnapshots
            ?? Array(repeating: nil, count: entries.count)
    }
}

public enum TransferInterventionReason: String, Codable, Hashable, Sendable {
    case alreadyCopied
    case alreadyMoved
    case missingSource
    case destinationConflict
    case sourceChanged
    case requestChanged
    case operationInProgress
}

public struct TransferIntervention: Error, Codable, Equatable, Sendable {
    public let taskID: TaskID
    public let itemID: String
    public let itemName: String
    public let reason: TransferInterventionReason

    public init(
        taskID: TaskID,
        itemID: String,
        itemName: String,
        reason: TransferInterventionReason
    ) {
        self.taskID = taskID
        self.itemID = itemID
        self.itemName = itemName
        self.reason = reason
    }
}

extension TransferIntervention: LocalizedError {
    public var errorDescription: String? {
        "Transfer requires intervention for \(itemName): \(reason.rawValue)"
    }
}

public enum TransferExecutionError: Error, Equatable, Sendable {
    case injectedFailure(completedItems: Int)
}

extension TransferExecutionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .injectedFailure(let completedItems):
            "Injected transfer failure after \(completedItems) item(s)"
        }
    }
}

public struct TransferFileOperations: Sendable {
    public typealias SnapshotSource = @Sendable (
        _ entry: TransferEntrySnapshot
    ) async throws -> TransferEntrySnapshot?
    public typealias SnapshotDestination = @Sendable (
        _ entry: TransferEntrySnapshot,
        _ destination: Location
    ) async throws -> TransferEntrySnapshot?
    public typealias Execute = @Sendable (
        _ operation: TransferOperation,
        _ entry: TransferEntrySnapshot,
        _ destination: Location,
        _ overwrite: TransferOverwritePolicy
    ) async throws -> Void

    private let snapshotSource: SnapshotSource
    private let snapshotDestination: SnapshotDestination
    private let executeItem: Execute

    public init(
        snapshotSource: @escaping SnapshotSource,
        snapshotDestination: @escaping SnapshotDestination,
        execute: @escaping Execute
    ) {
        self.snapshotSource = snapshotSource
        self.snapshotDestination = snapshotDestination
        executeItem = execute
    }

    func sourceSnapshot(for entry: TransferEntrySnapshot) async throws -> TransferEntrySnapshot? {
        try await snapshotSource(entry)
    }

    func destinationSnapshot(
        for entry: TransferEntrySnapshot,
        at destination: Location
    ) async throws -> TransferEntrySnapshot? {
        try await snapshotDestination(entry, destination)
    }

    func execute(
        _ operation: TransferOperation,
        entry: TransferEntrySnapshot,
        destination: Location,
        overwrite: TransferOverwritePolicy
    ) async throws {
        try await executeItem(operation, entry, destination, overwrite)
    }
}

public extension TransferFileOperations {
    static func local(provider: LocalFileProvider = LocalFileProvider()) -> Self {
        Self(
            snapshotSource: { entry in
                guard let url = entry.location.localURL else {
                    throw OpenFinderError.unsupportedLocation(entry.location)
                }
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return TransferEntrySnapshot(try await provider.stat(entry.location))
            },
            snapshotDestination: { entry, destination in
                let target = try localTarget(for: entry, destination: destination)
                guard FileManager.default.fileExists(atPath: target.path) else { return nil }
                return TransferEntrySnapshot(
                    try await provider.stat(.local(path: target.path))
                )
            },
            execute: { operation, entry, destination, overwrite in
                let replace = overwrite == .replaceExisting
                switch operation {
                case .copy:
                    _ = try await provider.copy(
                        [entry.item],
                        to: destination,
                        overwriteExisting: replace
                    )
                case .move:
                    _ = try await provider.move(
                        [entry.item],
                        to: destination,
                        overwriteExisting: replace
                    )
                }
            }
        )
    }

    private static func localTarget(
        for entry: TransferEntrySnapshot,
        destination: Location
    ) throws -> URL {
        guard let directory = destination.localURL else {
            throw OpenFinderError.unsupportedLocation(destination)
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw OpenFinderError.operationFailed("Transfer destination is not a directory")
        }
        guard !entry.name.isEmpty,
              entry.name != ".",
              entry.name != "..",
              !entry.name.contains("/"),
              !entry.name.contains("\\")
        else {
            throw OpenFinderError.invalidFileName(entry.name)
        }
        return directory.appendingPathComponent(entry.name, isDirectory: entry.item.isDirectory)
    }
}

public actor TransferCoordinator {
    public enum FaultPoint: Equatable, Sendable {
        case beforeItem(Int)
        case afterItem(Int)
    }

    public typealias Progress = @Sendable (TaskProgressSnapshot) async -> Void
    public typealias BeforeEffects = @Sendable () async throws -> Void

    private struct Attempt: Sendable {
        let request: TransferRequest
        var completedItemIDs: Set<String>
    }

    private var attempts: [TaskID: Attempt] = [:]
    private var runningTasks: Set<TaskID> = []

    public init() {}

    public nonisolated static func support(
        from source: FileSourceID,
        to destination: FileSourceID,
        overwrite: TransferOverwritePolicy
    ) -> FileCapabilitySupport {
        if overwrite == .replaceExisting, destination.isRemote {
            return .unsupported(.remoteOverwrite)
        }
        switch (source, destination) {
        case (.local, _), (_, .local):
            return .supported
        case (.remote(let sourceAccount, let sourceConnector),
              .remote(let destinationAccount, let destinationConnector)):
            return sourceAccount == destinationAccount
                && sourceConnector == destinationConnector
                ? .supported
                : .unsupported(.crossSource)
        }
    }

    public func execute(
        _ request: TransferRequest,
        operations: TransferFileOperations,
        progress: Progress? = nil,
        beforeEffects: BeforeEffects? = nil,
        faultPoint: FaultPoint? = nil
    ) async throws {
        guard !runningTasks.contains(request.taskID) else {
            throw intervention(for: request.entries.first, request: request, reason: .operationInProgress)
        }
        runningTasks.insert(request.taskID)
        defer { runningTasks.remove(request.taskID) }

        let sourceID = try resolvedSourceID(for: request.source)
        let destinationID = try resolvedSourceID(for: request.destination)
        let support = Self.support(
            from: sourceID,
            to: destinationID,
            overwrite: request.overwrite
        )
        if case .unsupported(let reason) = support { throw reason }

        if let existing = attempts[request.taskID], existing.request != request {
            throw intervention(for: request.entries.first, request: request, reason: .requestChanged)
        }
        guard request.destinationSnapshots.count == request.entries.count else {
            throw intervention(
                for: request.entries.first,
                request: request,
                reason: .requestChanged
            )
        }
        let completed = attempts[request.taskID]?.completedItemIDs ?? []

        for (index, entry) in request.entries.enumerated() {
            try Task.checkCancellation()
            try validate(entry: entry, belongsTo: sourceID, request: request)
            let current = try await operations.sourceSnapshot(for: entry)
            let destination = try await operations.destinationSnapshot(
                for: entry,
                at: request.destination
            )
            if completed.contains(entry.id) {
                throw intervention(
                    for: entry,
                    request: request,
                    reason: request.operation == .copy ? .alreadyCopied : .alreadyMoved
                )
            }
            guard let current else {
                let reason: TransferInterventionReason =
                    request.operation == .move && destination != nil
                    ? .alreadyMoved
                    : .missingSource
                throw intervention(for: entry, request: request, reason: reason)
            }
            guard entry.matches(current) else {
                throw intervention(for: entry, request: request, reason: .sourceChanged)
            }
            if request.overwrite == .rejectExisting {
                if let destination {
                    let reason: TransferInterventionReason =
                        request.operation == .copy && entry.contentMatches(destination)
                        ? .alreadyCopied
                        : .destinationConflict
                    throw intervention(for: entry, request: request, reason: reason)
                }
            } else {
                let expected = request.destinationSnapshots[index]
                let destinationMatches: Bool
                switch (expected, destination) {
                case (nil, nil):
                    destinationMatches = true
                case (.some(let expected), .some(let destination)):
                    destinationMatches = expected.matches(destination)
                case (.none, .some), (.some, .none):
                    destinationMatches = false
                }
                guard destinationMatches else {
                    throw intervention(
                        for: entry,
                        request: request,
                        reason: .destinationConflict
                    )
                }
            }
        }

        attempts[request.taskID] = Attempt(request: request, completedItemIDs: completed)
        try await beforeEffects?()
        for (index, entry) in request.entries.enumerated() {
            try Task.checkCancellation()
            let ordinal = index + 1
            if faultPoint == .beforeItem(ordinal) {
                throw TransferExecutionError.injectedFailure(completedItems: index)
            }
            await progress?(.init(
                fraction: Double(index) / Double(max(request.entries.count, 1)),
                phase: "transfer",
                detail: "\(request.operation.rawValue.capitalized) \(entry.name)",
                completed: index,
                total: request.entries.count,
                unit: "items"
            ))
            try await operations.execute(
                request.operation,
                entry: entry,
                destination: request.destination,
                overwrite: request.overwrite
            )
            attempts[request.taskID]?.completedItemIDs.insert(entry.id)
            await progress?(.init(
                fraction: Double(ordinal) / Double(max(request.entries.count, 1)),
                phase: "transfer",
                detail: "Transferred \(entry.name)",
                completed: ordinal,
                total: request.entries.count,
                unit: "items"
            ))
            if faultPoint == .afterItem(ordinal) {
                throw TransferExecutionError.injectedFailure(completedItems: ordinal)
            }
        }
    }

    private func resolvedSourceID(for location: Location) throws -> FileSourceID {
        switch location.fileLocation {
        case .resolved(let location):
            location.sourceID
        case .unsupported(let reason):
            throw reason
        }
    }

    private func validate(
        entry: TransferEntrySnapshot,
        belongsTo sourceID: FileSourceID,
        request: TransferRequest
    ) throws {
        let entrySource = try resolvedSourceID(for: entry.location)
        guard entrySource == sourceID else {
            throw intervention(for: entry, request: request, reason: .sourceChanged)
        }
        if case .local = sourceID,
           let itemURL = entry.location.localURL,
           let sourceURL = request.source.localURL,
           itemURL.deletingLastPathComponent().standardizedFileURL
            != sourceURL.standardizedFileURL {
            throw intervention(for: entry, request: request, reason: .sourceChanged)
        }
    }

    private func intervention(
        for entry: TransferEntrySnapshot?,
        request: TransferRequest,
        reason: TransferInterventionReason
    ) -> TransferIntervention {
        TransferIntervention(
            taskID: request.taskID,
            itemID: entry?.id ?? "",
            itemName: entry?.name ?? "",
            reason: reason
        )
    }
}
