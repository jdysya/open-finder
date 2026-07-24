import Foundation

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
}
