import Foundation

public enum TaskKind: Codable, Hashable, Sendable {
    case plugin(pluginID: String, actionID: String)
    case localCopy
    case localMove
    case localDelete
    case videoAnalysis
    case webDAVUpload
    case webDAVDownload
    case webDAVOperation
    case rcloneOperation

    private enum CodingKeys: String, CodingKey { case type, pluginID, actionID }
    private enum Kind: String, Codable { case plugin, localCopy, localMove, localDelete, videoAnalysis, webDAVUpload, webDAVDownload, webDAVOperation, rcloneOperation }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .plugin:
            self = .plugin(pluginID: try container.decode(String.self, forKey: .pluginID), actionID: try container.decode(String.self, forKey: .actionID))
        case .localCopy: self = .localCopy
        case .localMove: self = .localMove
        case .localDelete: self = .localDelete
        case .videoAnalysis: self = .videoAnalysis
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
        case .videoAnalysis: try container.encode(Kind.videoAnalysis, forKey: .type)
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

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        case .queued, .running, .cancelling: false
        }
    }
}

public struct TaskRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: TaskKind
    public var title: String
    public var status: TaskStatus
    public var progress: Double?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var inputSummary: String
    public var resultSummary: String?
    public var errorMessage: String?
    public var logFilePath: String?
    public var retryCount: Int
    public var clipboardText: String?

    public init(
        id: UUID = UUID(),
        kind: TaskKind,
        title: String,
        status: TaskStatus = .queued,
        progress: Double? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        inputSummary: String = "",
        resultSummary: String? = nil,
        errorMessage: String? = nil,
        logFilePath: String? = nil,
        retryCount: Int = 0,
        clipboardText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.progress = progress
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.inputSummary = inputSummary
        self.resultSummary = resultSummary
        self.errorMessage = errorMessage
        self.logFilePath = logFilePath
        self.retryCount = retryCount
        self.clipboardText = clipboardText
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
