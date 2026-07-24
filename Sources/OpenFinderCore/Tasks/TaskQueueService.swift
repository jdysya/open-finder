import Foundation

public typealias TaskOperation = @Sendable (TaskExecutionContext) async throws -> TaskResult

public struct TaskRequest: Sendable {
    public let kind: TaskKind
    public let title: String
    public let inputSummary: String
    public let resourceKey: String?
    public let descriptor: TaskDescriptorEnvelope?
    public let operation: TaskOperation?

    public init(
        kind: TaskKind,
        title: String,
        inputSummary: String = "",
        resourceKey: String? = nil,
        descriptor: TaskDescriptorEnvelope? = nil,
        operation: TaskOperation? = nil
    ) {
        self.kind = kind
        self.title = title
        self.inputSummary = inputSummary
        self.resourceKey = descriptor?.resourceKey ?? resourceKey
        self.descriptor = descriptor
        self.operation = operation
    }

    var isDurable: Bool {
        descriptor != nil && operation == nil
    }
}

public actor TaskExecutionContext {
    private let taskID: UUID
    private let queue: TaskQueueService

    init(taskID: UUID, queue: TaskQueueService) {
        self.taskID = taskID
        self.queue = queue
    }

    public nonisolated var id: UUID { taskID }

    public var isCancelled: Bool {
        get async { await queue.isCancellationRequested(taskID) }
    }

    public func updateProgress(_ progress: Double?, _ message: String? = nil) async {
        await queue.updateProgress(taskID, progress, message: message)
    }

    public func updateProgress(_ snapshot: TaskProgressSnapshot) async {
        await queue.updateProgress(taskID, snapshot)
    }

    public func appendLog(_ message: String, level: String = "info") async {
        await queue.appendLog(taskID, message, level: level)
    }

    public func markEffectsCommitted() async throws {
        try await queue.markEffectsCommitted(taskID)
    }
}

public actor TaskQueueService {
    private var queue: [UUID] = []
    private var reservedTaskIDs: Set<UUID> = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var starting: Set<UUID> = []
    private var records: [UUID: TaskRecord] = [:]
    private var requests: [UUID: TaskRequest] = [:]
    private var logStorage: [UUID: [TaskLogLine]] = [:]
    private var cancellationRequests: Set<UUID> = []
    private var effectsCommittedTasks: Set<UUID> = []
    private var runningResourceKeys: Set<String> = []
    private var maxConcurrentTasks: Int
    private var handlerRegistry: TaskHandlerRegistry?
    private let store: (any TaskStore)?
    private var nextReservedQueueOrdinal: UInt64 = 1

    public init(
        maxConcurrentTasks: Int = 2,
        handlerRegistry: TaskHandlerRegistry? = nil,
        store: (any TaskStore)? = nil
    ) {
        self.maxConcurrentTasks = max(1, maxConcurrentTasks)
        self.handlerRegistry = handlerRegistry
        self.store = store
    }

    public func updateMaxConcurrentTasks(_ value: Int) async {
        maxConcurrentTasks = max(1, value)
        await startNextIfPossible()
    }

    public func currentMaxConcurrentTasks() -> Int { maxConcurrentTasks }

    public func installHandlerRegistry(_ registry: TaskHandlerRegistry) throws {
        guard handlerRegistry == nil else {
            throw TaskHandlerRegistryError.handlerUnavailable(
                "A durable task handler registry is already installed"
            )
        }
        handlerRegistry = registry
    }

    public func restorePersistedHistory(
        _ persistedTasks: [PersistedTaskState]
    ) async throws {
        guard records.isEmpty, queue.isEmpty, running.isEmpty, starting.isEmpty else {
            throw OpenFinderError.operationFailed(
                "Persisted task history must be restored into an empty queue"
            )
        }
        let ordered = persistedTasks.sorted {
            $0.descriptor.queueOrdinal < $1.descriptor.queueOrdinal
        }
        for persisted in ordered {
            let descriptor = persisted.descriptor
            guard descriptor.taskID == persisted.record.id,
                  persisted.record.descriptor == descriptor
            else {
                throw GRDBTaskStoreError.descriptorRecordMismatch
            }
            let request = TaskRequest(
                kind: persisted.record.kind,
                title: persisted.record.title,
                inputSummary: persisted.record.inputSummary,
                resourceKey: descriptor.resourceKey,
                descriptor: descriptor
            )
            requests[descriptor.taskID] = request
            records[descriptor.taskID] = persisted.record
            logStorage[descriptor.taskID] = persisted.logs
            nextReservedQueueOrdinal = max(
                nextReservedQueueOrdinal,
                descriptor.queueOrdinal &+ 1
            )

            guard persisted.record.status == .queued else { continue }
            guard persisted.record.startedAt == nil else {
                records[descriptor.taskID]?.markInterrupted()
                await persistRecord(descriptor.taskID)
                continue
            }
            if let reasonCode = await unavailableRecoveryReason(for: descriptor) {
                await finish(
                    descriptor.taskID,
                    status: .unavailable,
                    result: nil,
                    error: nil,
                    reasonCode: reasonCode
                )
                continue
            }
            queue.append(descriptor.taskID)
        }
    }

    public func resumeRecoveredTasks() async {
        await startNextIfPossible()
    }

    public func reserveQueueOrdinal() -> UInt64 {
        let reserved = nextReservedQueueOrdinal
        nextReservedQueueOrdinal &+= 1
        return reserved
    }

    @discardableResult
    public func enqueue(_ request: TaskRequest) async throws -> UUID {
        try await enqueue(request, persist: request.isDurable)
    }

    private func enqueue(_ request: TaskRequest, persist: Bool) async throws -> UUID {
        if let activeDuplicateID = activeDuplicateID(for: request) {
            return activeDuplicateID
        }
        let id = request.descriptor?.taskID ?? UUID()
        guard records[id] == nil, !reservedTaskIDs.contains(id) else {
            throw OpenFinderError.operationFailed("Task \(id) is already enqueued")
        }
        reservedTaskIDs.insert(id)
        defer { reservedTaskIDs.remove(id) }
        let record = TaskRecord(
            id: id,
            kind: request.kind,
            title: request.title,
            inputSummary: request.inputSummary,
            descriptor: request.descriptor
        )
        if let ordinal = request.descriptor?.queueOrdinal {
            nextReservedQueueOrdinal = max(nextReservedQueueOrdinal, ordinal &+ 1)
        }
        if persist, let descriptor = request.descriptor, let store {
            try await store.enqueue(descriptor: descriptor, record: record)
        }
        requests[id] = request
        records[id] = record
        logStorage[id] = []
        if handlerRegistry == nil,
           case .unavailable(let reasonCode) = request.descriptor?.availability {
            await finish(id, status: .unavailable, result: nil, error: nil, reasonCode: reasonCode)
            return id
        }
        queue.append(id)
        await startNextIfPossible()
        return id
    }

    @discardableResult
    public func recoverPersistedTask(
        _ request: TaskRequest,
        descriptorData: Data,
        fallbackID: UUID = UUID()
    ) async throws -> UUID {
        try await recoverPersistedTask(
            request,
            descriptorData: descriptorData,
            persisted: PersistedTaskRecoverySnapshot(status: .queued, startedAt: nil),
            fallbackID: fallbackID
        )
    }

    @discardableResult
    public func recoverPersistedTask(
        _ request: TaskRequest,
        descriptorData: Data,
        persisted: PersistedTaskRecoverySnapshot,
        fallbackID: UUID = UUID()
    ) async throws -> UUID {
        let descriptor: TaskDescriptorEnvelope
        do {
            descriptor = try JSONDecoder().decode(TaskDescriptorEnvelope.self, from: descriptorData)
        } catch {
            guard records[fallbackID] == nil else { return fallbackID }
            records[fallbackID] = TaskRecord(
                id: fallbackID,
                kind: request.kind,
                title: request.title,
                inputSummary: request.inputSummary
            )
            logStorage[fallbackID] = []
            await finish(
                fallbackID,
                status: .unavailable,
                result: nil,
                error: nil,
                reasonCode: .malformedPayload
            )
            return fallbackID
        }
        let recoveredRequest = TaskRequest(
            kind: request.kind,
            title: request.title,
            inputSummary: request.inputSummary,
            resourceKey: request.resourceKey,
            descriptor: descriptor
        )
        if records[descriptor.taskID] != nil {
            return descriptor.taskID
        }
        guard !persisted.isQueuedAndNeverStarted else {
            return try await enqueue(recoveredRequest, persist: false)
        }

        requests[descriptor.taskID] = recoveredRequest
        var record = TaskRecord(
            id: descriptor.taskID,
            kind: request.kind,
            title: request.title,
            startedAt: persisted.startedAt,
            inputSummary: request.inputSummary,
            descriptor: descriptor
        )
        record.markInterrupted()
        records[descriptor.taskID] = record
        logStorage[descriptor.taskID] = []
        await persistRecord(descriptor.taskID)
        return descriptor.taskID
    }

    public func record(for id: UUID) -> TaskRecord? { records[id] }

    public func history() -> [TaskRecord] {
        records.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func logs(for id: UUID) -> [TaskLogLine] { logStorage[id] ?? [] }

    public func cancel(_ id: UUID) async {
        guard let record = records[id], !record.status.isTerminal else { return }
        if let index = queue.firstIndex(of: id) {
            cancellationRequests.insert(id)
            queue.remove(at: index)
            await finish(id, status: .cancelled, result: nil, error: nil)
            cancellationRequests.remove(id)
            return
        }
        if starting.contains(id) {
            guard !effectsCommittedTasks.contains(id) else { return }
            cancellationRequests.insert(id)
            await setStatus(.cancelling, for: id)
            return
        }
        if let runningTask = running[id] {
            guard !effectsCommittedTasks.contains(id) else { return }
            cancellationRequests.insert(id)
            await setStatus(.cancelling, for: id)
            runningTask.cancel()
        }
    }

    @discardableResult
    public func retry(_ id: UUID) async throws -> UUID {
        guard let original = requests[id], let oldRecord = records[id] else {
            throw OpenFinderError.itemNotFound(id.uuidString)
        }
        guard oldRecord.status.isTerminal else {
            throw OpenFinderError.operationFailed("Only terminal tasks can be retried")
        }
        if let activeDuplicateID = activeDuplicateID(for: original) {
            return activeDuplicateID
        }
        let retryID = UUID()
        let retryDescriptor = original.descriptor?.retried(
            taskID: retryID,
            queueOrdinal: nextQueueOrdinal()
        )
        let retryRequest = TaskRequest(
            kind: original.kind,
            title: original.title,
            inputSummary: original.inputSummary,
            resourceKey: original.resourceKey,
            descriptor: retryDescriptor,
            operation: original.operation
        )
        let retryRecord = TaskRecord(
            id: retryID,
            kind: original.kind,
            title: original.title,
            inputSummary: original.inputSummary,
            retryCount: oldRecord.retryCount + 1,
            descriptor: retryDescriptor
        )
        if retryRequest.isDurable, let retryDescriptor, let store {
            try await store.enqueue(descriptor: retryDescriptor, record: retryRecord)
        }
        requests[retryID] = retryRequest
        records[retryID] = retryRecord
        logStorage[retryID] = []
        if handlerRegistry == nil,
           case .unavailable(let reasonCode) = retryDescriptor?.availability {
            await finish(retryID, status: .unavailable, result: nil, error: nil, reasonCode: reasonCode)
            return retryID
        }
        queue.append(retryID)
        await startNextIfPossible()
        return retryID
    }

    public func appendLog(_ id: UUID, _ message: String, level: String = "info") async {
        guard records[id]?.status.isTerminal == false else { return }
        let line = TaskLogLine(taskID: id, level: level, message: message)
        if requests[id]?.isDurable == true, let store {
            try? await store.append(log: line)
        }
        logStorage[id, default: []].append(line)
    }

    public func updateProgress(_ id: UUID, _ progress: Double?, message: String? = nil) async {
        guard records[id]?.status.isTerminal == false else { return }
        records[id]?.progress = progress
        await persistRecord(id)
        if let message { await appendLog(id, message) }
    }

    public func updateProgress(_ id: UUID, _ snapshot: TaskProgressSnapshot) async {
        guard records[id]?.status.isTerminal == false else { return }
        let previousPhase = records[id]?.progressDetail?.phase
        records[id]?.progress = snapshot.fraction
        records[id]?.progressDetail = snapshot
        await persistRecord(id)
        if let phase = snapshot.phase, phase != previousPhase {
            await appendLog(id, [phase, snapshot.detail].compactMap { $0 }.joined(separator: ": "))
        } else if snapshot.phase == nil, let detail = snapshot.detail, !detail.isEmpty {
            await appendLog(id, detail)
        }
    }

    public func isCancellationRequested(_ id: UUID) -> Bool {
        cancellationRequests.contains(id) || Task.isCancelled
    }

    func markEffectsCommitted(_ id: UUID) async throws {
        guard
            records[id]?.status.isTerminal == false,
            !cancellationRequests.contains(id),
            !Task.isCancelled
        else {
            throw CancellationError()
        }
        effectsCommittedTasks.insert(id)
        await persistRecord(id)
    }

    public func waitForTerminalStatus(_ id: UUID, timeout: TimeInterval) async throws -> TaskRecord {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let record = records[id], record.status.isTerminal { return record }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw OpenFinderError.timeout("Timed out waiting for task \(id)")
    }

    private func startNextIfPossible() async {
        while running.count + starting.count < maxConcurrentTasks {
            guard let index = queue.firstIndex(where: { id in
                guard let key = requests[id]?.resourceKey else { return true }
                return !runningResourceKeys.contains(key)
            }) else { return }
            let id = queue.remove(at: index)
            guard let request = requests[id], let queuedRecord = records[id] else { continue }
            if let resourceKey = request.resourceKey {
                runningResourceKeys.insert(resourceKey)
            }
            records[id]?.status = .running
            records[id]?.startedAt = Date()
            starting.insert(id)
            do {
                try await updateStoredRecord(id)
            } catch {
                starting.remove(id)
                if let resourceKey = request.resourceKey {
                    runningResourceKeys.remove(resourceKey)
                }
                if cancellationRequests.contains(id) {
                    await finish(id, status: .cancelled, result: nil, error: nil)
                    cancellationRequests.remove(id)
                } else {
                    records[id] = queuedRecord
                    queue.insert(id, at: index)
                }
                return
            }
            starting.remove(id)
            if cancellationRequests.contains(id) {
                if let resourceKey = request.resourceKey {
                    runningResourceKeys.remove(resourceKey)
                }
                await finish(id, status: .cancelled, result: nil, error: nil)
                cancellationRequests.remove(id)
                continue
            }
            let handle = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                await self.run(id: id, request: request)
            }
            running[id] = handle
        }
    }

    private func run(id: UUID, request: TaskRequest) async {
        let context = TaskExecutionContext(taskID: id, queue: self)
        let events = TaskEventSink(
            consume: { [weak self] event in
                guard let self else { return false }
                return await self.consume(event, for: id)
            },
            commitEffects: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.markEffectsCommitted(id)
            }
        )
        do {
            let result: TaskResult
            if let descriptor = request.descriptor, let handlerRegistry {
                result = try await handlerRegistry.execute(descriptor: descriptor, events: events)
            } else if let operation = request.operation {
                result = try await operation(context)
            } else {
                throw TaskHandlerRegistryError.unknownHandler(
                    handlerID: request.descriptor?.handlerID ?? "",
                    payloadVersion: request.descriptor?.payloadVersion ?? 0
                )
            }
            await events.complete()
            if (cancellationRequests.contains(id) || Task.isCancelled)
                && !effectsCommittedTasks.contains(id) {
                await finish(id, status: .cancelled, result: nil, error: nil)
            } else {
                await finish(id, status: .succeeded, result: result, error: nil)
            }
        } catch is CancellationError {
            await events.complete()
            await finish(id, status: .cancelled, result: nil, error: nil)
        } catch let error as TaskHandlerRegistryError {
            await events.complete()
            await finish(
                id,
                status: .unavailable,
                result: nil,
                error: nil,
                reasonCode: registryReason(for: error)
            )
        } catch let intervention as TransferIntervention {
            await events.complete()
            await finish(
                id,
                status: .failed,
                result: nil,
                error: intervention,
                reasonCode: .init(intervention: intervention.reason)
            )
        } catch {
            await events.complete()
            await finish(
                id,
                status: cancellationRequests.contains(id) ? .cancelled : .failed,
                result: nil,
                error: error
            )
        }
        if let resourceKey = request.resourceKey {
            runningResourceKeys.remove(resourceKey)
        }
        running[id] = nil
        cancellationRequests.remove(id)
        effectsCommittedTasks.remove(id)
        await startNextIfPossible()
    }

    private func consume(_ event: TaskEvent, for id: UUID) async -> Bool {
        guard records[id]?.status.isTerminal == false else { return false }
        switch event {
        case .progress(let snapshot):
            await updateProgress(id, snapshot)
        case .log(let message, let level):
            await appendLog(id, message, level: level)
        case .status(let status):
            guard !status.isTerminal else { return false }
            await setStatus(status, for: id)
        }
        return true
    }

    private func registryReason(for error: TaskHandlerRegistryError) -> TaskStatusReasonCode {
        switch error {
        case .duplicateRegistration, .handlerUnavailable:
            .handlerUnavailable
        case .unknownHandler(_, let payloadVersion):
            payloadVersion == 1 ? .unknownHandler : .unsupportedPayloadVersion
        }
    }

    private func activeDuplicateID(for request: TaskRequest) -> UUID? {
        guard let descriptor = request.descriptor,
              let idempotencyKey = descriptor.idempotencyKey
        else {
            return nil
        }
        return requests.first { id, existingRequest in
            guard records[id]?.status.isTerminal == false,
                  let existing = existingRequest.descriptor
            else {
                return false
            }
            return existing.handlerID == descriptor.handlerID
                && existing.payloadVersion == descriptor.payloadVersion
                && existing.idempotencyKey == idempotencyKey
        }?.key
    }

    private func unavailableRecoveryReason(
        for descriptor: TaskDescriptorEnvelope
    ) async -> TaskStatusReasonCode? {
        switch descriptor.availability {
        case .unavailable(let reasonCode):
            return reasonCode
        case .available:
            break
        }
        guard let handlerRegistry else {
            return .handlerUnavailable
        }
        do {
            _ = try await handlerRegistry.handler(
                for: descriptor.handlerID,
                payloadVersion: descriptor.payloadVersion
            )
            return nil
        } catch let error as TaskHandlerRegistryError {
            return registryReason(for: error)
        } catch {
            return .handlerUnavailable
        }
    }

    private func finish(
        _ id: UUID,
        status: TaskStatus,
        result: TaskResult?,
        error: Error?,
        reasonCode: TaskStatusReasonCode? = nil
    ) async {
        guard records[id]?.status.isTerminal == false else { return }
        if let error {
            records[id]?.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            await appendLog(id, records[id]?.errorMessage ?? "Task failed", level: "error")
        }
        records[id]?.status = status
        records[id]?.finishedAt = Date()
        records[id]?.reasonCode = reasonCode
        if status == .succeeded { records[id]?.progress = 1.0 }
        if let result {
            records[id]?.resultSummary = result.summary
            records[id]?.clipboardText = result.clipboard
        }
        await persistRecord(id)
    }

    private func setStatus(_ status: TaskStatus, for id: UUID) async {
        guard records[id]?.status.isTerminal == false else { return }
        records[id]?.status = status
        await persistRecord(id)
    }

    private func persistRecord(_ id: UUID) async {
        try? await updateStoredRecord(id)
    }

    private func updateStoredRecord(_ id: UUID) async throws {
        guard
            requests[id]?.isDurable == true,
            let record = records[id],
            let store
        else { return }
        try await store.update(
            record: record,
            effectsCommitted: effectsCommittedTasks.contains(id)
        )
    }

    private func nextQueueOrdinal() -> UInt64 {
        reserveQueueOrdinal()
    }
}
