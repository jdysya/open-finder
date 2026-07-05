import Foundation

public enum PluginOutputEvent: Equatable, Sendable {
    case log(level: String, message: String)
    case progress(fraction: Double, message: String?)
    case result(status: String, message: String?, clipboard: String?, artifacts: [PluginArtifact])

    public var clipboardText: String? {
        if case .result(_, _, let clipboard, _) = self { clipboard } else { nil }
    }

    public var resultStatus: String? {
        if case .result(let status, _, _, _) = self { status } else { nil }
    }

    public var resultMessage: String? {
        if case .result(_, let message, _, _) = self { message } else { nil }
    }

    public var isFailureResult: Bool {
        guard let status = resultStatus?.lowercased() else { return false }
        return ["failure", "failed", "error"].contains(status)
    }
}

public struct PluginArtifact: Codable, Hashable, Sendable {
    public let type: String
    public let content: String

    public init(type: String, content: String) {
        self.type = type
        self.content = content
    }
}

public enum PluginOutputParser {
    private struct RawEvent: Decodable {
        let type: String
        let level: String?
        let message: String?
        let fraction: Double?
        let status: String?
        let clipboard: String?
        let artifacts: [PluginArtifact]?
    }

    public static func parseNDJSON(_ output: String) throws -> [PluginOutputEvent] {
        try output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            return try parseLine(line)
        }
    }

    public static func parseLine(_ line: String) throws -> PluginOutputEvent {
        let event = try JSONDecoder.openFinder.decode(RawEvent.self, from: Data(line.utf8))
        switch event.type {
        case "log":
            return .log(level: event.level ?? "info", message: event.message ?? "")
        case "progress":
            return .progress(fraction: event.fraction ?? 0, message: event.message)
        case "result":
            return .result(status: event.status ?? "success", message: event.message, clipboard: event.clipboard, artifacts: event.artifacts ?? [])
        default:
            throw OpenFinderError.invalidPluginOutput("Unknown event type \(event.type)")
        }
    }
}
