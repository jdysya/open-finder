import Foundation

public enum HTTPPluginEventType: String, Codable, Equatable, Sendable {
    case log
    case progress
    case result
}

public struct HTTPPluginArtifact: Codable, Equatable, Sendable {
    public let type: String
    public let relativePath: String
    public let mediaType: String
    public let byteCount: Int
    public let sha256: String

    public init(type: String, relativePath: String, mediaType: String, byteCount: Int, sha256: String) {
        self.type = type
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct HTTPPluginEvent: Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: Int
    public let taskID: UUID
    public let type: HTTPPluginEventType
    public let pluginOutputEvent: PluginOutputEvent
    public let artifacts: [HTTPPluginArtifact]

    fileprivate init(
        schemaVersion: Int,
        eventID: Int,
        taskID: UUID,
        type: HTTPPluginEventType,
        pluginOutputEvent: PluginOutputEvent,
        artifacts: [HTTPPluginArtifact] = []
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.taskID = taskID
        self.type = type
        self.pluginOutputEvent = pluginOutputEvent
        self.artifacts = artifacts
    }
}

extension HTTPPluginEvent {
    private struct CommonFields: Decodable {
        let schemaVersion: Int
        let eventID: Int
        let taskID: UUID
        let type: String
    }

    private struct LogFields: Decodable {
        let level: String
        let message: String
    }

    private struct ProgressFields: Decodable {
        let fraction: Double
        let message: String?
        let phase: String?
        let completed: Int?
        let total: Int?
        let unit: String?
    }

    private struct ResultFields: Decodable {
        let status: String
        let message: String?
        let clipboard: String?
        let artifacts: [HTTPPluginArtifact]
    }

    static func decode(
        _ data: Data,
        sseEventID: Int,
        sseEventType: String,
        expectedTaskID: UUID
    ) throws -> HTTPPluginEvent {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ServerSentEventParserError.invalidJSON
            }
            object = decoded
        } catch let error as ServerSentEventParserError {
            throw error
        } catch {
            throw ServerSentEventParserError.invalidJSON
        }

        let common: CommonFields = try decodeJSON(CommonFields.self, from: data)
        guard common.schemaVersion == 1 else {
            throw ServerSentEventParserError.unsupportedSchemaVersion(common.schemaVersion)
        }
        guard common.taskID == expectedTaskID else {
            throw ServerSentEventParserError.taskIDMismatch(expected: expectedTaskID, actual: common.taskID)
        }
        guard common.eventID == sseEventID else {
            throw ServerSentEventParserError.eventIDMismatch(sse: sseEventID, json: common.eventID)
        }
        guard common.type == sseEventType else {
            throw ServerSentEventParserError.eventTypeMismatch(sse: sseEventType, json: common.type)
        }
        guard let type = HTTPPluginEventType(rawValue: common.type) else {
            throw ServerSentEventParserError.invalidEvent(field: "type")
        }

        switch type {
        case .log:
            try rejectUnknownKeys(in: object, allowed: commonKeys.union(["level", "message"]))
            let fields: LogFields = try decodeJSON(LogFields.self, from: data)
            guard !fields.level.isEmpty else {
                throw ServerSentEventParserError.invalidEvent(field: "level")
            }
            return .init(
                schemaVersion: common.schemaVersion,
                eventID: common.eventID,
                taskID: common.taskID,
                type: type,
                pluginOutputEvent: .log(level: fields.level, message: fields.message)
            )

        case .progress:
            try rejectUnknownKeys(
                in: object,
                allowed: commonKeys.union(["fraction", "message", "phase", "completed", "total", "unit"])
            )
            try rejectNullValues(in: object, keys: ["message", "phase", "completed", "total", "unit"])
            let fields: ProgressFields = try decodeJSON(ProgressFields.self, from: data)
            guard fields.fraction.isFinite, (0 ... 1).contains(fields.fraction) else {
                throw ServerSentEventParserError.invalidEvent(field: "fraction")
            }
            guard (fields.completed == nil) == (fields.total == nil) else {
                throw ServerSentEventParserError.invalidEvent(field: "completed/total")
            }
            if let completed = fields.completed, let total = fields.total {
                guard completed >= 0, total >= 0, completed <= total else {
                    throw ServerSentEventParserError.invalidEvent(field: "completed/total")
                }
            }
            return .init(
                schemaVersion: common.schemaVersion,
                eventID: common.eventID,
                taskID: common.taskID,
                type: type,
                pluginOutputEvent: .progress(.init(
                    fraction: fields.fraction,
                    message: fields.message,
                    phase: fields.phase,
                    completed: fields.completed,
                    total: fields.total,
                    unit: fields.unit
                ))
            )

        case .result:
            try rejectUnknownKeys(
                in: object,
                allowed: commonKeys.union(["status", "message", "clipboard", "artifacts"])
            )
            try rejectNullValues(in: object, keys: ["message", "clipboard"])
            let fields: ResultFields = try decodeJSON(ResultFields.self, from: data)
            guard ["success", "failure", "cancelled"].contains(fields.status) else {
                throw ServerSentEventParserError.invalidEvent(field: "status")
            }
            try validateArtifacts(fields.artifacts, in: object)
            return .init(
                schemaVersion: common.schemaVersion,
                eventID: common.eventID,
                taskID: common.taskID,
                type: type,
                pluginOutputEvent: .result(
                    status: fields.status,
                    message: fields.message,
                    clipboard: fields.clipboard,
                    artifacts: fields.artifacts.map {
                        .init(type: $0.type, file: .init(
                            relativePath: $0.relativePath,
                            mediaType: $0.mediaType,
                            byteCount: $0.byteCount,
                            sha256: $0.sha256
                        ))
                    }
                ),
                artifacts: fields.artifacts
            )
        }
    }

    private static let commonKeys: Set<String> = ["schemaVersion", "eventID", "taskID", "type"]
    private static let artifactKeys: Set<String> = ["type", "relativePath", "mediaType", "byteCount", "sha256"]

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder.openFinder.decode(type, from: data)
        } catch {
            throw ServerSentEventParserError.invalidJSON
        }
    }

    private static func rejectUnknownKeys(in object: [String: Any], allowed: Set<String>) throws {
        if let key = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ServerSentEventParserError.invalidEvent(field: key)
        }
    }

    private static func rejectNullValues(in object: [String: Any], keys: Set<String>) throws {
        if let key = keys.sorted().first(where: { object[$0] is NSNull }) {
            throw ServerSentEventParserError.invalidEvent(field: key)
        }
    }

    private static func validateArtifacts(_ artifacts: [HTTPPluginArtifact], in object: [String: Any]) throws {
        guard let rawArtifacts = object["artifacts"] as? [Any], rawArtifacts.count == artifacts.count else {
            throw ServerSentEventParserError.invalidJSON
        }

        for (artifact, rawArtifact) in zip(artifacts, rawArtifacts) {
            guard let rawObject = rawArtifact as? [String: Any] else {
                throw ServerSentEventParserError.invalidJSON
            }
            try rejectUnknownKeys(in: rawObject, allowed: artifactKeys)
            guard !artifact.type.isEmpty else {
                throw ServerSentEventParserError.invalidEvent(field: "artifacts.type")
            }
            guard isConfinedRelativePath(artifact.relativePath) else {
                throw ServerSentEventParserError.invalidEvent(field: "artifacts.relativePath")
            }
            guard isMediaType(artifact.mediaType) else {
                throw ServerSentEventParserError.invalidEvent(field: "artifacts.mediaType")
            }
            guard artifact.byteCount >= 0 else {
                throw ServerSentEventParserError.invalidEvent(field: "artifacts.byteCount")
            }
            guard artifact.sha256.utf8.count == 64,
                  artifact.sha256.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) })
            else {
                throw ServerSentEventParserError.invalidEvent(field: "artifacts.sha256")
            }
        }
    }

    private static func isConfinedRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        let bytes = Array(path.utf8)
        if bytes.count >= 3,
           ((0x41 ... 0x5a).contains(bytes[0]) || (0x61 ... 0x7a).contains(bytes[0])),
           bytes[1] == 0x3a,
           bytes[2] == 0x2f || bytes[2] == 0x5c
        {
            return false
        }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func isMediaType(_ mediaType: String) -> Bool {
        guard !mediaType.contains(where: \.isWhitespace),
              let slash = mediaType.firstIndex(of: "/"),
              slash != mediaType.startIndex,
              mediaType.index(after: slash) != mediaType.endIndex
        else {
            return false
        }
        return !mediaType[..<slash].contains("/")
    }
}
