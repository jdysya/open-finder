import Foundation

public enum TaskEvent: Equatable, Sendable {
    case progress(TaskProgressSnapshot)
    case log(message: String, level: String)
    case status(TaskStatus)
}

public actor TaskEventSink {
    typealias EventConsumer = @Sendable (TaskEvent) async -> Bool
    typealias EffectsCommitter = @Sendable () async throws -> Void

    private struct PendingEvent {
        let sequence: UInt64
        let event: TaskEvent
    }

    private let consume: EventConsumer
    private let commitEffects: EffectsCommitter
    private var pending: [PendingEvent] = []
    private var eventWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private var history: [TaskEvent] = []
    private var nextSequence: UInt64 = 0
    private var draining = false
    private var accepting = true
    private var terminal = false
    private var effectsCommitted = false

    init(
        consume: @escaping EventConsumer,
        commitEffects: @escaping EffectsCommitter
    ) {
        self.consume = consume
        self.commitEffects = commitEffects
    }

    @discardableResult
    public func updateProgress(_ snapshot: TaskProgressSnapshot) async -> Bool {
        await submit(.progress(snapshot))
    }

    @discardableResult
    public func updateProgress(_ progress: Double?, _ message: String? = nil) async -> Bool {
        let snapshot = TaskProgressSnapshot(fraction: progress ?? 0, detail: message)
        return await submit(.progress(snapshot))
    }

    @discardableResult
    public func appendLog(_ message: String, level: String = "info") async -> Bool {
        await submit(.log(message: message, level: level))
    }

    @discardableResult
    public func updateStatus(_ status: TaskStatus) async -> Bool {
        await submit(.status(status))
    }

    public func markEffectsCommitted() async throws {
        if effectsCommitted { return }
        guard accepting, !terminal else { throw CancellationError() }
        await flush()
        guard accepting, !terminal else { throw CancellationError() }
        try await commitEffects()
        effectsCommitted = true
    }

    public func flush() async {
        guard draining || !pending.isEmpty else { return }
        await withCheckedContinuation { continuation in
            flushWaiters.append(continuation)
        }
    }

    public func eventHistory() -> [TaskEvent] {
        history
    }

    func complete() async {
        accepting = false
        await flush()
        terminal = true
    }

    private func submit(_ event: TaskEvent) async -> Bool {
        guard accepting, !terminal else { return false }
        let sequence = nextSequence
        nextSequence &+= 1
        pending.append(.init(sequence: sequence, event: event))
        if case .status(let status) = event, status.isTerminal {
            accepting = false
        }
        if !draining {
            draining = true
            Task { await self.drain() }
        }
        return await withCheckedContinuation { continuation in
            eventWaiters[sequence] = continuation
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let item = pending.removeFirst()
            let accepted = terminal ? false : await consume(item.event)
            if accepted {
                history.append(item.event)
                if case .status(let status) = item.event, status.isTerminal {
                    terminal = true
                }
            }
            eventWaiters.removeValue(forKey: item.sequence)?.resume(returning: accepted)
        }
        draining = false
        flushWaiters.forEach { $0.resume() }
        flushWaiters.removeAll()
    }
}
