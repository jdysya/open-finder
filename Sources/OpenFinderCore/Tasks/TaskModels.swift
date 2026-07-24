import Foundation

public enum TaskKind: Codable, Hashable, Sendable {
    case plugin(pluginID: String, actionID: String)
    case localCopy
    case localMove
    case localDelete
    case webDAVUpload
    case webDAVDownload
    case webDAVOperation
    case rcloneOperation

    private enum CodingKeys: String, CodingKey { case type, pluginID, actionID }
    private enum Kind: String, Codable { case plugin, localCopy, localMove, localDelete, webDAVUpload, webDAVDownload, webDAVOperation, rcloneOperation }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .plugin:
            self = .plugin(pluginID: try container.decode(String.self, forKey: .pluginID), actionID: try container.decode(String.self, forKey: .actionID))
        case .localCopy: self = .localCopy
        case .localMove: self = .localMove
        case .localDelete: self = .localDelete
        case .webDAVUpload: self = .webDAVUpload
        case .webDAVDownload: self = .webDAVDownload
        case .webDAVOperation: self = .webDAVOperation
        case .rcloneOperation: self = .rcloneOperation
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .plugin(let pluginID, let actionID):
            try container.encode(Kind.plugin, forKey: .type)
            try container.encode(pluginID, forKey: .pluginID)
            try container.encode(actionID, forKey: .actionID)
        case .localCopy: try container.encode(Kind.localCopy, forKey: .type)
        case .localMove: try container.encode(Kind.localMove, forKey: .type)
        case .localDelete: try container.encode(Kind.localDelete, forKey: .type)
        case .webDAVUpload: try container.encode(Kind.webDAVUpload, forKey: .type)
        case .webDAVDownload: try container.encode(Kind.webDAVDownload, forKey: .type)
        case .webDAVOperation: try container.encode(Kind.webDAVOperation, forKey: .type)
        case .rcloneOperation: try container.encode(Kind.rcloneOperation, forKey: .type)
        }
    }
}

public enum TaskStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelling
    case cancelled
    case interrupted
    case unavailable

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .interrupted, .unavailable: true
        case .queued, .running, .cancelling: false
        }
    }
}

public struct PersistedTaskRecoverySnapshot: Codable, Hashable, Sendable {
    public let status: TaskStatus
    public let startedAt: Date?

    public init(status: TaskStatus, startedAt: Date?) {
        self.status = status
        self.startedAt = startedAt
    }

    var isQueuedAndNeverStarted: Bool {
        status == .queued && startedAt == nil
    }
}

public enum TaskStatusReasonCode: String, Codable, Hashable, Sendable {
    case recoveryInterrupted
    case unknownHandler
    case unsupportedPayloadVersion
    case malformedPayload
    case handlerUnavailable
}

public enum DurableTaskHandlerID: String, CaseIterable, Codable, Hashable, Sendable {
    case pluginExecute = "plugin.execute.v1"
    case transferCopy = "transfer.copy.v1"
    case transferMove = "transfer.move.v1"
}

public struct TaskAttemptLineage: Codable, Hashable, Sendable {
    public let rootTaskID: UUID
    public let parentTaskID: UUID?
    public let attempt: Int

    public init(rootTaskID: UUID, parentTaskID: UUID? = nil, attempt: Int = 1) {
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.attempt = attempt
    }
}

public enum TaskDescriptorAvailability: Hashable, Sendable {
    case available(DurableTaskHandlerID)
    case unavailable(TaskStatusReasonCode)
}

public struct TaskDescriptorEnvelope: Codable, Hashable, Sendable {
    public let taskID: UUID
    public let handlerID: String
    public let payloadVersion: Int
    public let resourceKey: String?
    public let idempotencyKey: String?
    public let lineage: TaskAttemptLineage
    public let queueOrdinal: UInt64
    public let redactedPayload: [String: String]

    public init(
        taskID: UUID,
        handlerID: String,
        payloadVersion: Int,
        resourceKey: String? = nil,
        idempotencyKey: String? = nil,
        lineage: TaskAttemptLineage,
        queueOrdinal: UInt64,
        redactedPayload: [String: String] = [:]
    ) {
        self.taskID = taskID
        self.handlerID = handlerID
        self.payloadVersion = payloadVersion
        self.resourceKey = resourceKey
        self.idempotencyKey = idempotencyKey
        self.lineage = lineage
        self.queueOrdinal = queueOrdinal
        self.redactedPayload = Self.sanitize(redactedPayload)
    }

    public var availability: TaskDescriptorAvailability {
        guard let handler = DurableTaskHandlerID(rawValue: handlerID) else {
            return .unavailable(.unknownHandler)
        }
        guard payloadVersion == 1 else {
            return .unavailable(.unsupportedPayloadVersion)
        }
        return .available(handler)
    }

    public func retried(taskID: UUID, queueOrdinal: UInt64) -> TaskDescriptorEnvelope {
        TaskDescriptorEnvelope(
            taskID: taskID,
            handlerID: handlerID,
            payloadVersion: payloadVersion,
            resourceKey: resourceKey,
            idempotencyKey: idempotencyKey,
            lineage: .init(
                rootTaskID: lineage.rootTaskID,
                parentTaskID: self.taskID,
                attempt: lineage.attempt + 1
            ),
            queueOrdinal: queueOrdinal,
            redactedPayload: redactedPayload
        )
    }

    private enum CodingKeys: String, CodingKey {
        case taskID
        case handlerID
        case payloadVersion
        case resourceKey
        case idempotencyKey
        case lineage
        case queueOrdinal
        case redactedPayload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decode(UUID.self, forKey: .taskID)
        handlerID = try container.decode(String.self, forKey: .handlerID)
        payloadVersion = try container.decode(Int.self, forKey: .payloadVersion)
        resourceKey = try container.decodeIfPresent(String.self, forKey: .resourceKey)
        idempotencyKey = try container.decodeIfPresent(String.self, forKey: .idempotencyKey)
        lineage = try container.decode(TaskAttemptLineage.self, forKey: .lineage)
        queueOrdinal = try container.decode(UInt64.self, forKey: .queueOrdinal)
        redactedPayload = Self.sanitize(
            try container.decode([String: String].self, forKey: .redactedPayload)
        )
    }

    private static func sanitize(_ payload: [String: String]) -> [String: String] {
        payload.filter { key, _ in
            let normalized = key.lowercased()
            return !["secret", "token", "password", "credential", "bookmark", "authorization"]
                .contains(where: normalized.contains)
        }
    }
}

public struct TaskRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: TaskKind
    public var title: String
    public var status: TaskStatus
    public var progress: Double?
    public var progressDetail: TaskProgressSnapshot?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var inputSummary: String
    public var resultSummary: String?
    public var errorMessage: String?
    public var logFilePath: String?
    public var retryCount: Int
    public var clipboardText: String?
    public var descriptor: TaskDescriptorEnvelope?
    public var reasonCode: TaskStatusReasonCode?

    public init(
        id: UUID = UUID(),
        kind: TaskKind,
        title: String,
        status: TaskStatus = .queued,
        progress: Double? = nil,
        progressDetail: TaskProgressSnapshot? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        inputSummary: String = "",
        resultSummary: String? = nil,
        errorMessage: String? = nil,
        logFilePath: String? = nil,
        retryCount: Int = 0,
        clipboardText: String? = nil,
        descriptor: TaskDescriptorEnvelope? = nil,
        reasonCode: TaskStatusReasonCode? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.progress = progress
        self.progressDetail = progressDetail
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.inputSummary = inputSummary
        self.resultSummary = resultSummary
        self.errorMessage = errorMessage
        self.logFilePath = logFilePath
        self.retryCount = retryCount
        self.clipboardText = clipboardText
        self.descriptor = descriptor
        self.reasonCode = reasonCode
    }

    public mutating func markInterrupted(
        reasonCode: TaskStatusReasonCode = .recoveryInterrupted,
        at date: Date = Date()
    ) {
        guard !status.isTerminal else { return }
        status = .interrupted
        self.reasonCode = reasonCode
        finishedAt = date
    }
}

public struct TaskProgressSnapshot: Codable, Hashable, Sendable {
    public let fraction: Double
    public let phase: String?
    public let detail: String?
    public let completed: Int?
    public let total: Int?
    public let unit: String?

    public init(
        fraction: Double,
        phase: String? = nil,
        detail: String? = nil,
        completed: Int? = nil,
        total: Int? = nil,
        unit: String? = nil
    ) {
        self.fraction = fraction
        self.phase = phase
        self.detail = detail
        self.completed = completed
        self.total = total
        self.unit = unit
    }
}

public struct TaskLogLine: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let date: Date
    public let level: String
    public let message: String

    public init(id: UUID = UUID(), taskID: UUID, date: Date = Date(), level: String = "info", message: String) {
        self.id = id
        self.taskID = taskID
        self.date = date
        self.level = level
        self.message = message
    }
}

public enum TaskResult: Sendable, Equatable {
    case success(summary: String, clipboard: String?)

    public var summary: String {
        switch self { case .success(let summary, _): summary }
    }

    public var clipboard: String? {
        switch self { case .success(_, let clipboard): clipboard }
    }
}
