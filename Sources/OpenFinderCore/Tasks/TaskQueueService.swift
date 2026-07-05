import Foundation

public typealias TaskOperation = (TaskExecutionContext) async throws -> TaskResult

public struct TaskRequest: @unchecked Sendable {
    public let kind: TaskKind
    public let title: String
    public let inputSummary: String
    public let operation: TaskOperation

    public init(kind: TaskKind, title: String, inputSummary: String = "", operation: @escaping TaskOperation) {
        self.kind = kind
        self.title = title
        self.inputSummary = inputSummary
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

    public var isCancelled: Bool {
        get async { await queue.isCancellationRequested(taskID) }
    }

    public func updateProgress(_ progress: Double?, _ message: String? = nil) async {
        await queue.updateProgress(taskID, progress, message: message)
    }

    public func appendLog(_ message: String, level: String = "info") async {
        await queue.appendLog(taskID, message, level: level)
    }
}

public actor TaskQueueService {
    private var queue: [UUID] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var records: [UUID: TaskRecord] = [:]
    private var requests: [UUID: TaskRequest] = [:]
    private var logStorage: [UUID: [TaskLogLine]] = [:]
    private var cancellationRequests: Set<UUID> = []
    private let maxConcurrentTasks: Int

    public init(maxConcurrentTasks: Int = 2) {
        self.maxConcurrentTasks = max(1, maxConcurrentTasks)
    }

    @discardableResult
    public func enqueue(_ request: TaskRequest) async throws -> UUID {
        let id = UUID()
        requests[id] = request
        records[id] = TaskRecord(id: id, kind: request.kind, title: request.title, inputSummary: request.inputSummary)
        logStorage[id] = []
        queue.append(id)
        startNextIfPossible()
        return id
    }

    public func record(for id: UUID) -> TaskRecord? { records[id] }

    public func history() -> [TaskRecord] {
        records.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func logs(for id: UUID) -> [TaskLogLine] { logStorage[id] ?? [] }

    public func cancel(_ id: UUID) async {
        cancellationRequests.insert(id)
        if let index = queue.firstIndex(of: id) {
            queue.remove(at: index)
            finish(id, status: .cancelled, result: nil, error: nil)
            return
        }
        if let runningTask = running[id] {
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
        requests[retryID] = original
        records[retryID] = TaskRecord(
            id: retryID,
            kind: original.kind,
            title: original.title,
            inputSummary: original.inputSummary,
            retryCount: oldRecord.retryCount + 1
        )
        logStorage[retryID] = []
        queue.append(retryID)
        startNextIfPossible()
        return retryID
    }

    public func appendLog(_ id: UUID, _ message: String, level: String = "info") {
        logStorage[id, default: []].append(.init(taskID: id, level: level, message: message))
    }

    public func updateProgress(_ id: UUID, _ progress: Double?, message: String? = nil) {
        records[id]?.progress = progress
        if let message { appendLog(id, message) }
    }

    public func isCancellationRequested(_ id: UUID) -> Bool {
        cancellationRequests.contains(id) || Task.isCancelled
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
        while running.count < maxConcurrentTasks, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let request = requests[id] else { continue }
            records[id]?.status = .running
            records[id]?.startedAt = Date()
            let handle = Task { [weak self] in
                guard let self else { return }
                await self.run(id: id, request: request)
            }
            running[id] = handle
        }
    }

    private func run(id: UUID, request: TaskRequest) async {
        let context = TaskExecutionContext(taskID: id, queue: self)
        do {
            let result = try await request.operation(context)
            if cancellationRequests.contains(id) || Task.isCancelled {
                finish(id, status: .cancelled, result: nil, error: nil)
            } else {
                finish(id, status: .succeeded, result: result, error: nil)
            }
        } catch is CancellationError {
            finish(id, status: .cancelled, result: nil, error: nil)
        } catch {
            finish(id, status: cancellationRequests.contains(id) ? .cancelled : .failed, result: nil, error: error)
        }
        running[id] = nil
        cancellationRequests.remove(id)
        startNextIfPossible()
    }

    private func finish(_ id: UUID, status: TaskStatus, result: TaskResult?, error: Error?) {
        records[id]?.status = status
        records[id]?.finishedAt = Date()
        if status == .succeeded { records[id]?.progress = 1.0 }
        if let result {
            records[id]?.resultSummary = result.summary
            records[id]?.clipboardText = result.clipboard
        }
        if let error {
            records[id]?.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            appendLog(id, records[id]?.errorMessage ?? "Task failed", level: "error")
        }
    }
}
