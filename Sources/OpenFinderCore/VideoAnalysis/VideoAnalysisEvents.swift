import Foundation

public enum VideoAnalysisStage: String, Codable, Hashable, Sendable {
    case preparing
    case sceneDetection
    case keyframeExtraction
    case nudityAnalysis
    case tagAnalysis
    case reportGeneration
    case finished
}

public struct VideoAnalysisLog: Equatable, Sendable {
    public let level: String
    public let message: String

    public init(level: String, message: String) {
        self.level = level
        self.message = message
    }
}

public struct VideoAnalysisProgress: Equatable, Sendable {
    public let taskID: UUID
    public let videoPath: String
    public let stage: VideoAnalysisStage
    public let detail: String
    public let fraction: Double

    public init(taskID: UUID, videoPath: String, stage: VideoAnalysisStage, detail: String, fraction: Double) {
        self.taskID = taskID
        self.videoPath = videoPath
        self.stage = stage
        self.detail = detail
        self.fraction = fraction
    }
}

public enum VideoAnalysisWorkerEvent: Equatable, Sendable {
    case log(VideoAnalysisLog)
    case progress(VideoAnalysisProgress)
    case result(VideoAnalysisResult)
}

public enum VideoAnalysisProtocolError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case unknownEventType(String)
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version): "Unsupported video analysis schema version: \(version)"
        case .unknownEventType(let type): "Unknown video analysis event type: \(type)"
        case .missingField(let field): "Video analysis event is missing required field: \(field)"
        }
    }
}

public enum VideoAnalysisWorkerEventParser {
    private struct RawEvent: Decodable {
        let schemaVersion: Int
        let type: String
        let level: String?
        let message: String?
        let taskID: UUID?
        let videoPath: String?
        let stage: VideoAnalysisStage?
        let detail: String?
        let fraction: Double?
        let result: VideoAnalysisResult?
    }

    public static func parse(line: String) throws -> VideoAnalysisWorkerEvent {
        let raw = try JSONDecoder.openFinder.decode(RawEvent.self, from: Data(line.utf8))
        guard raw.schemaVersion == 1 else {
            throw VideoAnalysisProtocolError.unsupportedSchemaVersion(raw.schemaVersion)
        }
        switch raw.type {
        case "log":
            return .log(.init(
                level: raw.level ?? "info",
                message: try required(raw.message, field: "message")
            ))
        case "progress":
            return .progress(.init(
                taskID: try required(raw.taskID, field: "taskID"),
                videoPath: try required(raw.videoPath, field: "videoPath"),
                stage: try required(raw.stage, field: "stage"),
                detail: raw.detail ?? "",
                fraction: try required(raw.fraction, field: "fraction")
            ))
        case "result":
            let result = try required(raw.result, field: "result")
            guard result.schemaVersion == 1 else {
                throw VideoAnalysisProtocolError.unsupportedSchemaVersion(result.schemaVersion)
            }
            return .result(result)
        default:
            throw VideoAnalysisProtocolError.unknownEventType(raw.type)
        }
    }

    private static func required<Value>(_ value: Value?, field: String) throws -> Value {
        guard let value else { throw VideoAnalysisProtocolError.missingField(field) }
        return value
    }
}
