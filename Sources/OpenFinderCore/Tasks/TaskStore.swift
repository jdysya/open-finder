import Foundation

public struct PersistedTaskState: Sendable {
    public let descriptor: TaskDescriptorEnvelope
    public let record: TaskRecord
    public let logs: [TaskLogLine]

    public init(
        descriptor: TaskDescriptorEnvelope,
        record: TaskRecord,
        logs: [TaskLogLine]
    ) {
        self.descriptor = descriptor
        self.record = record
        self.logs = logs
    }
}

public protocol TaskStore: Sendable {
    func enqueue(
        descriptor: TaskDescriptorEnvelope,
        record: TaskRecord
    ) async throws

    func update(
        record: TaskRecord,
        effectsCommitted: Bool
    ) async throws

    func append(log: TaskLogLine) async throws

    func interruptActiveTasks(at date: Date) async throws

    func loadPersistedTasks() async throws -> [PersistedTaskState]
}

public extension TaskStore {
    func interruptActiveTasks(at _: Date) async throws {
        throw GRDBTaskStoreError.durableReadUnavailable
    }

    func loadPersistedTasks() async throws -> [PersistedTaskState] {
        throw GRDBTaskStoreError.durableReadUnavailable
    }
}
