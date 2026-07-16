import Foundation

public enum PluginConnectionState: String, Equatable, Sendable {
    case connecting
    case ready
    case degraded
    case unavailable
}

public enum PluginConnectionIssue: String, Equatable, Sendable {
    case missingEndpoint
    case invalidEndpoint
    case missingToken
    case authenticationFailed
    case serverUnavailable
    case incompatibleProtocol
    case incompatiblePlugin
    case invalidResponse
    case environmentUnavailable
}

public struct PluginConnectionRuntime: Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct PluginConnectionCheck: Identifiable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let message: String
    public let remediation: String?

    public init(id: String, status: String, message: String, remediation: String?) {
        self.id = id
        self.status = status
        self.message = message
        self.remediation = remediation
    }
}

public struct PluginConnectionStatus: Equatable, Sendable {
    public let state: PluginConnectionState
    public let issue: PluginConnectionIssue?
    public let guidance: String
    public let protocolVersion: Int?
    public let pluginID: String?
    public let pluginVersion: String?
    public let runtime: PluginConnectionRuntime?
    public let checks: [PluginConnectionCheck]

    public var canSubmit: Bool { state == .ready && issue == nil }

    public init(
        state: PluginConnectionState,
        issue: PluginConnectionIssue? = nil,
        guidance: String,
        protocolVersion: Int? = nil,
        pluginID: String? = nil,
        pluginVersion: String? = nil,
        runtime: PluginConnectionRuntime? = nil,
        checks: [PluginConnectionCheck] = []
    ) {
        self.state = state
        self.issue = issue
        self.guidance = guidance
        self.protocolVersion = protocolVersion
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.runtime = runtime
        self.checks = checks
    }
}

public protocol PluginConnectionChecking: Sendable {
    func check(
        manifest: PluginManifest,
        values: [String: String],
        secretReferences: [String: String]
    ) async -> PluginConnectionStatus
}
