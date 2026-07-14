import Foundation

public struct VideoAnalysisInputFile: Codable, Hashable, Sendable {
    public let path: String
    public let name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

public struct VideoAnalysisOptions: Codable, Hashable, Sendable {
    public let useJoyTag: Bool

    public init(useJoyTag: Bool = true) {
        self.useJoyTag = useJoyTag
    }
}

public struct VideoAnalysisRequest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let taskID: UUID
    public let files: [VideoAnalysisInputFile]
    public let options: VideoAnalysisOptions
    public let outputDirectory: String

    public init(
        schemaVersion: Int = 1,
        taskID: UUID,
        files: [VideoAnalysisInputFile],
        options: VideoAnalysisOptions = .init(),
        outputDirectory: String
    ) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.files = files
        self.options = options
        self.outputDirectory = outputDirectory
    }
}

public struct VideoAnalysisSummary: Codable, Hashable, Sendable {
    public let totalFrames: Int
    public let faceVisible: Int
    public let explicit: Int
    public let moderate: Int
    public let partial: Int
    public let none: Int

    public init(totalFrames: Int, faceVisible: Int, explicit: Int, moderate: Int, partial: Int, none: Int) {
        self.totalFrames = totalFrames
        self.faceVisible = faceVisible
        self.explicit = explicit
        self.moderate = moderate
        self.partial = partial
        self.none = none
    }
}

public enum VideoNudityLevel: String, Codable, Hashable, Sendable {
    case none
    case partial
    case moderate
    case explicit
    case unknown
}

public struct VideoAnalysisTagSuggestion: Codable, Hashable, Sendable {
    public let name: String
    public let category: String
    public let confidence: Double
    public let frameRatio: Double
    public let source: String
    public let modelVersion: String

    public init(name: String, category: String, confidence: Double, frameRatio: Double, source: String, modelVersion: String) {
        self.name = name
        self.category = category
        self.confidence = confidence
        self.frameRatio = frameRatio
        self.source = source
        self.modelVersion = modelVersion
    }
}

public struct VideoFrameAnalysis: Codable, Hashable, Sendable {
    public let index: Int
    public let timestamp: Double
    public let imagePath: String
    public let faceVisible: Bool
    public let faceCount: Int
    public let nudityLevel: VideoNudityLevel
    public let summary: String
    public let tags: [VideoAnalysisTagSuggestion]

    public init(index: Int, timestamp: Double, imagePath: String, faceVisible: Bool, faceCount: Int, nudityLevel: VideoNudityLevel, summary: String, tags: [VideoAnalysisTagSuggestion]) {
        self.index = index
        self.timestamp = timestamp
        self.imagePath = imagePath
        self.faceVisible = faceVisible
        self.faceCount = faceCount
        self.nudityLevel = nudityLevel
        self.summary = summary
        self.tags = tags
    }
}

public struct AnalyzedVideo: Codable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let summary: VideoAnalysisSummary
    public let frames: [VideoFrameAnalysis]
    public let suggestedTags: [VideoAnalysisTagSuggestion]
    public let reportPath: String?

    public init(path: String, name: String, summary: VideoAnalysisSummary, frames: [VideoFrameAnalysis], suggestedTags: [VideoAnalysisTagSuggestion], reportPath: String?) {
        self.path = path
        self.name = name
        self.summary = summary
        self.frames = frames
        self.suggestedTags = suggestedTags
        self.reportPath = reportPath
    }
}

public struct VideoAnalysisResult: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let taskID: UUID
    public let videos: [AnalyzedVideo]

    public init(schemaVersion: Int = 1, taskID: UUID, videos: [AnalyzedVideo]) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.videos = videos
    }
}
