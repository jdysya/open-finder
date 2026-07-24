import Foundation
import OpenFinderCore

@MainActor
extension ApplicationServices {
    func prepareDurableExecution() async throws {
        if let databaseOpenError {
            throw databaseOpenError
        }
        let composition = try compositionResult.get()
        let registry = try await composition.makeTaskHandlerRegistry()
        try await taskService.installHandlerRegistry(registry)
        if let recoveryStore {
            try await taskService.recoverPersistedTasks(from: recoveryStore)
        }
    }

    func attachReadiness(_ task: Task<Result<Void, any Error>, Never>) {
        taskService.attachReadinessTask(task)
    }

    func requireDurableReadiness() async throws {
        try await taskService.requireReadiness()
    }

    func resumeRecoveredWork() async {
        await taskService.resumeRecoveredTasks()
    }

    func taskProjection() async -> TaskApplicationProjection {
        await taskService.projection()
    }

    func cancelTask(_ id: UUID) async -> TaskApplicationProjection {
        await taskService.cancel(id)
    }

    func retryTask(_ id: UUID) async throws -> (UUID, TaskApplicationProjection) {
        try await taskService.retry(id)
    }

    func awaitTask(
        _ id: UUID,
        timeout: TimeInterval
    ) async throws -> (TaskRecord, TaskApplicationProjection) {
        try await taskService.waitForTerminalStatus(id, timeout: timeout)
    }

    func startTaskObservation(
        publish: @escaping @MainActor (TaskApplicationProjection) -> Void
    ) {
        taskService.startPolling(publish: publish)
    }

}
