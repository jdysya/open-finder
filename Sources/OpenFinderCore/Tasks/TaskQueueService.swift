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
    private var running: [UUID: Task<Void, Never>] = [:]
    private var records: [UUID: TaskRecord] = [:]
    private var requests: [UUID: TaskRequest] = [:]
    private var logStorage: [UUID: [TaskLogLine]] = [:]
    private var cancellationRequests: Set<UUID> = []
    private var effectsCommittedTasks: Set<UUID> = []
    private var runningResourceKeys: Set<String> = []
    private var maxConcurrentTasks: Int
    private let handlerRegistry: TaskHandlerRegistry?

    public init(
        maxConcurrentTasks: Int = 2,
        handlerRegistry: TaskHandlerRegistry? = nil
    ) {
        self.maxConcurrentTasks = max(1, maxConcurrentTasks)
        self.handlerRegistry = handlerRegistry
    }

    public func updateMaxConcurrentTasks(_ value: Int) {
        maxConcurrentTasks = max(1, value)
        startNextIfPossible()
    }

    public func currentMaxConcurrentTasks() -> Int { maxConcurrentTasks }

    @discardableResult
    public func enqueue(_ request: TaskRequest) async throws -> UUID {
        let id = request.descriptor?.taskID ?? UUID()
        requests[id] = request
        records[id] = TaskRecord(
            id: id,
            kind: request.kind,
            title: request.title,
            inputSummary: request.inputSummary,
            descriptor: request.descriptor
        )
        logStorage[id] = []
        if handlerRegistry == nil,
           case .unavailable(let reasonCode) = request.descriptor?.availability {
            finish(id, status: .unavailable, result: nil, error: nil, reasonCode: reasonCode)
            return id
        }
        queue.append(id)
        startNextIfPossible()
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
            records[fallbackID] = TaskRecord(
                id: fallbackID,
                kind: request.kind,
                title: request.title,
                inputSummary: request.inputSummary
            )
            logStorage[fallbackID] = []
            finish(
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
            descriptor: descriptor,
            operation: request.operation
        )
        guard !persisted.isQueuedAndNeverStarted else {
            return try await enqueue(recoveredRequest)
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
            finish(id, status: .cancelled, result: nil, error: nil)
            return
        }
        if let runningTask = running[id] {
            guard !effectsCommittedTasks.contains(id) else { return }
            cancellationRequests.insert(id)
            records[id]?.status = .cancelling
            runningTask.cancel()
        }
    }

    @discardableResult
    public func retry(_ id: UUID) async throws -> UUID {
        guard let original = requests[id], let oldRecord = records[id] else {
            throw OpenFinderError.itemNotFound(id.uuidString)
        }
        let retryID = UUID()
        let retryDescriptor = original.descriptor?.retried(
            taskID: retryID,
            queueOrdinal: (original.descriptor?.queueOrdinal ?? 0) &+ 1
        )
        requests[retryID] = TaskRequest(
            kind: original.kind,
            title: original.title,
            inputSummary: original.inputSummary,
            resourceKey: original.resourceKey,
            descriptor: retryDescriptor,
            operation: original.operation
        )
        records[retryID] = TaskRecord(
            id: retryID,
            kind: original.kind,
            title: original.title,
            inputSummary: original.inputSummary,
            retryCount: oldRecord.retryCount + 1,
            descriptor: retryDescriptor
        )
        logStorage[retryID] = []
        if handlerRegistry == nil,
           case .unavailable(let reasonCode) = retryDescriptor?.availability {
            finish(retryID, status: .unavailable, result: nil, error: nil, reasonCode: reasonCode)
            return retryID
        }
        queue.append(retryID)
        startNextIfPossible()
        return retryID
    }

    public func appendLog(_ id: UUID, _ message: String, level: String = "info") {
        guard records[id]?.status.isTerminal == false else { return }
        logStorage[id, default: []].append(.init(taskID: id, level: level, message: message))
    }

    public func updateProgress(_ id: UUID, _ progress: Double?, message: String? = nil) {
        guard records[id]?.status.isTerminal == false else { return }
        records[id]?.progress = progress
        if let message { appendLog(id, message) }
    }

    public func updateProgress(_ id: UUID, _ snapshot: TaskProgressSnapshot) {
        guard records[id]?.status.isTerminal == false else { return }
        let previousPhase = records[id]?.progressDetail?.phase
        records[id]?.progress = snapshot.fraction
        records[id]?.progressDetail = snapshot
        if let phase = snapshot.phase, phase != previousPhase {
            appendLog(id, [phase, snapshot.detail].compactMap { $0 }.joined(separator: ": "))
        } else if snapshot.phase == nil, let detail = snapshot.detail, !detail.isEmpty {
            appendLog(id, detail)
        }
    }

    public func isCancellationRequested(_ id: UUID) -> Bool {
        cancellationRequests.contains(id) || Task.isCancelled
    }

    func markEffectsCommitted(_ id: UUID) throws {
        guard
            records[id]?.status.isTerminal == false,
            !cancellationRequests.contains(id),
            !Task.isCancelled
        else {
            throw CancellationError()
        }
        effectsCommittedTasks.insert(id)
    }

    public func waitForTerminalStatus(_ id: UUID, timeout: TimeInterval) async throws -> TaskRecord {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let record = records[id], record.status.isTerminal { return record }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw OpenFinderError.timeout("Timed out waiting for task \(id)")
    }

    private func startNextIfPossible() {
        while running.count < maxConcurrentTasks {
            guard let index = queue.firstIndex(where: { id in
                guard let key = requests[id]?.resourceKey else { return true }
                return !runningResourceKeys.contains(key)
            }) else { return }
            let id = queue.remove(at: index)
            guard let request = requests[id] else { continue }
            if let resourceKey = request.resourceKey {
                runningResourceKeys.insert(resourceKey)
            }
            records[id]?.status = .running
            records[id]?.startedAt = Date()
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
                finish(id, status: .cancelled, result: nil, error: nil)
            } else {
                finish(id, status: .succeeded, result: result, error: nil)
            }
        } catch is CancellationError {
            await events.complete()
            finish(id, status: .cancelled, result: nil, error: nil)
        } catch let error as TaskHandlerRegistryError {
            await events.complete()
            finish(
                id,
                status: .unavailable,
                result: nil,
                error: nil,
                reasonCode: registryReason(for: error)
            )
        } catch {
            await events.complete()
            finish(id, status: cancellationRequests.contains(id) ? .cancelled : .failed, result: nil, error: error)
        }
        if let resourceKey = request.resourceKey {
            runningResourceKeys.remove(resourceKey)
        }
        running[id] = nil
        cancellationRequests.remove(id)
        effectsCommittedTasks.remove(id)
        startNextIfPossible()
    }

    private func consume(_ event: TaskEvent, for id: UUID) -> Bool {
        guard records[id]?.status.isTerminal == false else { return false }
        switch event {
        case .progress(let snapshot):
            updateProgress(id, snapshot)
        case .log(let message, let level):
            appendLog(id, message, level: level)
        case .status(let status):
            guard !status.isTerminal else { return false }
            records[id]?.status = status
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

    private func finish(
        _ id: UUID,
        status: TaskStatus,
        result: TaskResult?,
        error: Error?,
        reasonCode: TaskStatusReasonCode? = nil
    ) {
        guard records[id]?.status.isTerminal == false else { return }
        records[id]?.status = status
        records[id]?.finishedAt = Date()
        records[id]?.reasonCode = reasonCode
        if status == .succeeded { records[id]?.progress = 1.0 }
        if let result {
            records[id]?.resultSummary = result.summary
            records[id]?.clipboardText = result.clipboard
        }
        if let error {
            records[id]?.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            logStorage[id, default: []].append(.init(
                taskID: id,
                level: "error",
                message: records[id]?.errorMessage ?? "Task failed"
            ))
        }
    }
}
