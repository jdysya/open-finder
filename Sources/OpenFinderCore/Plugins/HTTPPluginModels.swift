import Foundation

public enum HTTPPluginError: Error, Equatable, Sendable {
    case invalidEndpoint
    case executionMismatch
    case missingConfiguration(String)
    case missingCredential(String)
    case invalidCredential(String)
    case invalidResponse(String)
    case server(status: Int, code: String, message: String, retryable: Bool)
    case transport(String)
}

extension HTTPPluginError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "HTTP plugin endpoint must be a canonical numeric loopback HTTP URL with an explicit port."
        case .executionMismatch:
            "The plugin runner does not match the manifest execution transport."
        case .missingConfiguration(let key):
            "Missing HTTP plugin configuration: \(key)"
        case .missingCredential(let key):
            "Missing HTTP plugin credential: \(key)"
        case .invalidCredential(let key):
            "Invalid HTTP plugin credential: \(key)"
        case .invalidResponse(let reason):
            "Invalid HTTP plugin response: \(reason)"
        case .server(let status, let code, let message, _):
            "HTTP plugin server error \(status) (\(code)): \(message)"
        case .transport(let message):
            "HTTP plugin transport failed: \(message)"
        }
    }
}

public enum HTTPPluginJobState: String, Codable, Equatable, Sendable {
    case queued, preparing, running, finalizing, succeeded, failed, cancelling, cancelled

    public var isTerminal: Bool {
        self == .succeeded || self == .failed || self == .cancelled
    }
}

public struct HTTPPluginHealth: Decodable, Equatable, Sendable {
    public struct Runtime: Decodable, Equatable, Sendable {
        public let name: String
        public let version: String
    }
    public struct Check: Decodable, Equatable, Sendable {
        public let id: String
        public let status: String
        public let message: String
        public let remediation: String?
    }
    public let schemaVersion: Int
    public let protocolVersion: Int
    public let status: String
    public let pluginID: String?
    public let pluginVersion: String?
    public let runtime: Runtime?
    public let checks: [Check]?
}

public struct HTTPPluginCapabilities: Decodable, Equatable, Sendable {
    public struct Action: Decodable, Equatable, Sendable { public let id: String }
    public struct Features: Decodable, Equatable, Sendable {
        public let sse: Bool
        public let polling: Bool
        public let cancellation: Bool
        public let fileArtifacts: Bool
    }
    public struct Limits: Decodable, Equatable, Sendable {
        public let maxRequestBytes: Int
        public let terminalRetentionSeconds: Int
        public let maxEventsPerJob: Int
        public let maxQueuedJobs: Int
    }
    public let schemaVersion: Int
    public let protocolVersion: Int
    public let pluginID: String
    public let pluginVersion: String
    public let actions: [Action]
    public let features: Features
    public let limits: Limits
}

public struct HTTPPluginSnapshot: Decodable, Equatable, Sendable {
    public struct Progress: Decodable, Equatable, Sendable {
        public let schemaVersion: Int
        public let eventID: Int
        public let taskID: UUID
        public let type: String
        public let fraction: Double
        public let message: String?
        public let phase: String?
        public let completed: Int?
        public let total: Int?
        public let unit: String?
    }
    public let schemaVersion: Int
    public let taskID: UUID
    public let state: HTTPPluginJobState
    public let createdAt: String
    public let updatedAt: String
    public let startedAt: String?
    public let finishedAt: String?
    public let lastEventID: Int
    public let resultAvailable: Bool
    public let progress: Progress?
}

struct HTTPPluginErrorEnvelope: Decodable {
    let schemaVersion: Int
    let code: String
    let message: String
    let retryable: Bool
}

struct HTTPPluginPreparedRequest: Sendable {
    let endpoint: HTTPPluginEndpoint
    let bearerToken: String
    let input: PluginInput
}

enum HTTPPluginRedactor {
    static func message(_ value: String, token: String) -> String {
        guard !token.isEmpty else { return value }
        return value.replacingOccurrences(of: token, with: "REDACTED")
    }

    static func event(_ event: PluginOutputEvent, token: String) -> PluginOutputEvent {
        switch event {
        case .log(let level, let value):
            return .log(level: message(level, token: token), message: message(value, token: token))
        case .progress(let progress):
            return .progress(.init(
                fraction: progress.fraction, message: progress.message.map { message($0, token: token) },
                phase: progress.phase.map { message($0, token: token) }, completed: progress.completed,
                total: progress.total, unit: progress.unit.map { message($0, token: token) }
            ))
        case .result(let status, let value, let clipboard, let artifacts):
            return .result(
                status: message(status, token: token), message: value.map { message($0, token: token) },
                clipboard: clipboard.map { message($0, token: token) },
                artifacts: artifacts.map {
                    .init(type: message($0.type, token: token), content: message($0.content, token: token))
                }
            )
        }
    }
}
