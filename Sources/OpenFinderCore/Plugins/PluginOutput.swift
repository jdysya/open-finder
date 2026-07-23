import Foundation

public enum PluginOutputEvent: Equatable, Sendable {
    case log(level: String, message: String)
    case progress(PluginProgress)
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

public struct PluginProgress: Equatable, Sendable {
    public let fraction: Double
    public let message: String?
    public let phase: String?
    public let completed: Int?
    public let total: Int?
    public let unit: String?

    public init(
        fraction: Double,
        message: String? = nil,
        phase: String? = nil,
        completed: Int? = nil,
        total: Int? = nil,
        unit: String? = nil
    ) {
        self.fraction = fraction
        self.message = message
        self.phase = phase
        self.completed = completed
        self.total = total
        self.unit = unit
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
        let phase: String?
        let completed: Int?
        let total: Int?
        let unit: String?
    }

    public static func parseNDJSON(_ output: String) throws -> [PluginOutputEvent] {
        try output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            return try parseLine(line)
        }
    }

    public static func parseLine(_ line: String) throws -> PluginOutputEvent {
        let data = Data(line.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let type = dictionary["type"] as? String else {
            throw OpenFinderError.invalidPluginOutput("Event must be a JSON object with a string type")
        }
        let allowedKeys: Set<String>
        let requiredKeys: Set<String>
        switch type {
        case "log":
            allowedKeys = ["type", "level", "message"]
            requiredKeys = ["type", "message"]
        case "progress":
            allowedKeys = ["type", "fraction", "message", "phase", "completed", "total", "unit"]
            requiredKeys = ["type", "fraction"]
        case "result":
            allowedKeys = ["type", "status", "message", "clipboard", "artifacts"]
            requiredKeys = ["type", "status"]
        default:
            throw OpenFinderError.invalidPluginOutput("Unknown event type \(type)")
        }
        let keys = Set(dictionary.keys)
        let unknownKeys = keys.subtracting(allowedKeys)
        guard unknownKeys.isEmpty else {
            throw OpenFinderError.invalidPluginOutput(
                "Unknown field(s) for \(type) event: \(unknownKeys.sorted().joined(separator: ", "))"
            )
        }
        let missingKeys = requiredKeys.subtracting(keys)
        guard missingKeys.isEmpty else {
            throw OpenFinderError.invalidPluginOutput(
                "Missing field(s) for \(type) event: \(missingKeys.sorted().joined(separator: ", "))"
            )
        }

        let event = try JSONDecoder.openFinder.decode(RawEvent.self, from: data)
        switch event.type {
        case "log":
            guard let message = event.message else {
                throw OpenFinderError.invalidPluginOutput("Log message must be a string")
            }
            return .log(level: event.level ?? "info", message: message)
        case "progress":
            guard let fraction = event.fraction, fraction.isFinite, (0 ... 1).contains(fraction) else {
                throw OpenFinderError.invalidPluginOutput("Progress fraction must be a finite number from 0 through 1")
            }
            guard (event.completed == nil) == (event.total == nil) else {
                throw OpenFinderError.invalidPluginOutput("Progress completed and total must be supplied together")
            }
            if let completed = event.completed, let total = event.total,
               completed < 0 || total <= 0 || completed > total {
                throw OpenFinderError.invalidPluginOutput("Progress completed and total are inconsistent")
            }
            return .progress(.init(
                fraction: fraction,
                message: event.message,
                phase: event.phase,
                completed: event.completed,
                total: event.total,
                unit: event.unit
            ))
        case "result":
            guard let status = event.status?.lowercased(),
                  ["success", "failure", "cancelled"].contains(status) else {
                throw OpenFinderError.invalidPluginOutput(
                    "Result status must be success, failure, or cancelled"
                )
            }
            return .result(status: status, message: event.message, clipboard: event.clipboard, artifacts: event.artifacts ?? [])
        default:
            throw OpenFinderError.invalidPluginOutput("Unknown event type \(event.type)")
        }
    }
}

public enum ProcessPluginEventValidator {
    public static func validate(_ events: [PluginOutputEvent]) throws {
        let terminalIndexes = events.indices.filter { events[$0].resultStatus != nil }
        guard terminalIndexes.count == 1 else {
            throw OpenFinderError.invalidPluginOutput(
                "Process output must contain exactly one terminal result event"
            )
        }
        guard terminalIndexes[0] == events.indices.last else {
            throw OpenFinderError.invalidPluginOutput(
                "Process output contains an event after its terminal result"
            )
        }
    }
}
