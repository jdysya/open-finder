import Foundation

typealias HTTPPluginSleep = @Sendable (Double) async throws -> Void

enum HTTPPluginSleeps {
    static let live: HTTPPluginSleep = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
}

actor HTTPPluginCancellationRegistry {
    typealias Operation = @Sendable () async -> Void

    private var operations: [UUID: Operation] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var pending: Set<UUID> = []

    func register(taskID: UUID, operation: @escaping Operation) {
        operations[taskID] = operation
        if pending.remove(taskID) != nil { start(taskID: taskID, operation: operation) }
    }

    func unregister(taskID: UUID) {
        operations.removeValue(forKey: taskID)
        tasks.removeValue(forKey: taskID)
        pending.remove(taskID)
    }

    func cancel(taskID: UUID) async {
        if let task = tasks[taskID] {
            await task.value
            return
        }
        guard let operation = operations[taskID] else {
            pending.insert(taskID)
            return
        }
        start(taskID: taskID, operation: operation)
        await tasks[taskID]?.value
    }

    private func start(taskID: UUID, operation: @escaping Operation) {
        guard tasks[taskID] == nil else { return }
        tasks[taskID] = Task { await operation() }
    }
}

enum HTTPPluginCancellation {
    static func send(
        transport: any HTTPPluginTransportProtocol,
        request: URLRequest,
        taskID: UUID,
        token: String,
        sleep: @escaping HTTPPluginSleep
    ) async {
        do {
            let response = try await firstResponse(transport: transport, request: request, sleep: sleep)
            guard [200, 202].contains(response.statusCode),
                  response.headers["openfinder-plugin-protocol"] == "1",
                  HTTPPluginResponseValidator.isJSON(response.headers["content-type"])
            else { return }
            _ = try HTTPPluginWire.snapshot(response.body, taskID: taskID)
        } catch {
            _ = HTTPPluginRedactor.message(error.localizedDescription, token: token)
        }
    }

    private static func firstResponse(
        transport: any HTTPPluginTransportProtocol,
        request: URLRequest,
        sleep: @escaping HTTPPluginSleep
    ) async throws -> HTTPPluginDataResponse {
        try await withThrowingTaskGroup(of: HTTPPluginDataResponse.self) { group in
            group.addTask { try await transport.data(for: request) }
            group.addTask {
                try await sleep(5)
                throw HTTPPluginError.transport("cancellation acknowledgement timed out")
            }
            guard let first = try await group.next() else {
                throw HTTPPluginError.transport("cancellation acknowledgement unavailable")
            }
            group.cancelAll()
            return first
        }
    }
}
