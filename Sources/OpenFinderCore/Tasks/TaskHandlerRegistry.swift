import Foundation

public enum TaskHandlerRegistryError: Error, Equatable, Sendable {
    case duplicateRegistration(handlerID: String, payloadVersion: Int)
    case unknownHandler(handlerID: String, payloadVersion: Int)
}

public struct TaskHandler: Sendable {
    public typealias Operation = @Sendable (
        _ descriptor: TaskDescriptorEnvelope,
        _ events: TaskEventSink
    ) async throws -> TaskResult

    public let handlerID: String
    public let payloadVersion: Int
    private let operation: Operation

    public init(
        handlerID: String,
        payloadVersion: Int,
        operation: @escaping Operation
    ) {
        self.handlerID = handlerID
        self.payloadVersion = payloadVersion
        self.operation = operation
    }

    func execute(
        descriptor: TaskDescriptorEnvelope,
        events: TaskEventSink
    ) async throws -> TaskResult {
        try await operation(descriptor, events)
    }
}

public actor TaskHandlerRegistry {
    private struct Key: Hashable {
        let handlerID: String
        let payloadVersion: Int
    }

    private var handlers: [Key: TaskHandler] = [:]

    public init() {}

    public func register(_ handler: TaskHandler) throws {
        let key = Key(handlerID: handler.handlerID, payloadVersion: handler.payloadVersion)
        guard handlers[key] == nil else {
            throw TaskHandlerRegistryError.duplicateRegistration(
                handlerID: handler.handlerID,
                payloadVersion: handler.payloadVersion
            )
        }
        handlers[key] = handler
    }

    public func handler(for handlerID: String, payloadVersion: Int) throws -> TaskHandler {
        let key = Key(handlerID: handlerID, payloadVersion: payloadVersion)
        guard let handler = handlers[key] else {
            throw TaskHandlerRegistryError.unknownHandler(
                handlerID: handlerID,
                payloadVersion: payloadVersion
            )
        }
        return handler
    }

    func execute(
        descriptor: TaskDescriptorEnvelope,
        events: TaskEventSink
    ) async throws -> TaskResult {
        let handler = try handler(
            for: descriptor.handlerID,
            payloadVersion: descriptor.payloadVersion
        )
        do {
            let result = try await handler.execute(descriptor: descriptor, events: events)
            await events.flush()
            return result
        } catch {
            await events.flush()
            throw error
        }
    }
}
