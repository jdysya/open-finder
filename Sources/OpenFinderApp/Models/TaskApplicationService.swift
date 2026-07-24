import Foundation
import OpenFinderCore

struct TaskApplicationProjection: Equatable {
    let records: [TaskRecord]
    let logs: [UUID: [TaskLogLine]]

    var hasActiveTasks: Bool {
        records.contains { !$0.status.isTerminal }
    }
}

@MainActor
final class TaskApplicationService {
    enum PollingState: Equatable {
        case stopped
        case waitingForReadiness
        case polling
    }

    let queue: TaskQueueService
    private var readinessTask: Task<Result<Void, any Error>, Never>?
    private var pollingTask: Task<Void, Never>?
    private(set) var pollingState = PollingState.stopped

    init(queue: TaskQueueService) {
        self.queue = queue
    }

    deinit {
        pollingTask?.cancel()
    }

    func attachReadinessTask(_ task: Task<Result<Void, any Error>, Never>) {
        readinessTask = task
    }

    func requireReadiness() async throws {
        guard let readinessTask else {
            throw AppDurableHandlerCompositionError.missingTaskHandler(.init(
                handlerID: DurableTaskHandlerID.pluginExecute.rawValue,
                payloadVersion: 1
            ))
        }
        try await readinessTask.value.get()
    }

    func installHandlerRegistry(_ registry: TaskHandlerRegistry) async throws {
        try await queue.installHandlerRegistry(registry)
    }

    func recoverPersistedTasks(from store: any TaskStore, at date: Date = Date()) async throws {
        try await store.interruptActiveTasks(at: date)
        let persistedTasks = try await store.loadPersistedTasks()
        try await queue.restorePersistedHistory(persistedTasks)
    }

    func resumeRecoveredTasks() async {
        await queue.resumeRecoveredTasks()
    }

    func projection() async -> TaskApplicationProjection {
        let records = await queue.history().sorted { $0.createdAt > $1.createdAt }
        var logs: [UUID: [TaskLogLine]] = [:]
        for record in records {
            logs[record.id] = await queue.logs(for: record.id)
        }
        return .init(records: records, logs: logs)
    }

    func cancel(_ id: UUID) async -> TaskApplicationProjection {
        await queue.cancel(id)
        return await projection()
    }

    func retry(_ id: UUID) async throws -> (UUID, TaskApplicationProjection) {
        let retryID = try await queue.retry(id)
        return (retryID, await projection())
    }

    func waitForTerminalStatus(
        _ id: UUID,
        timeout: TimeInterval
    ) async throws -> (TaskRecord, TaskApplicationProjection) {
        let record = try await queue.waitForTerminalStatus(id, timeout: timeout)
        return (record, await projection())
    }

    func reserveQueueOrdinal() async -> UInt64 {
        await queue.reserveQueueOrdinal()
    }

    func enqueue(_ request: TaskRequest) async throws -> UUID {
        try await queue.enqueue(request)
    }

    func startPolling(
        publish: @escaping @MainActor (TaskApplicationProjection) -> Void
    ) {
        pollingTask?.cancel()
        pollingState = .waitingForReadiness
        let readinessTask = readinessTask
        pollingTask = Task { [weak self] in
            do {
                guard let readinessTask else {
                    throw AppDurableHandlerCompositionError.missingTaskHandler(.init(
                        handlerID: DurableTaskHandlerID.pluginExecute.rawValue,
                        payloadVersion: 1
                    ))
                }
                try await readinessTask.value.get()
            } catch {
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            self?.pollingState = .polling
            while !Task.isCancelled {
                guard let projection = await self?.projection() else { return }
                publish(projection)
                let interval: UInt64 = projection.hasActiveTasks
                    ? 250_000_000
                    : 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }
}
