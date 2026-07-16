import Foundation

public enum VideoAnalysisPluginResultError: Error, Equatable, LocalizedError {
    case missingResultArtifact
    case malformedResultArtifact
    case taskIDMismatch
    case unsupportedSchemaVersion(Int)
    case invalidFileArtifact(ConfinedArtifactError)
    case invalidNestedAsset(ConfinedArtifactError)

    public var errorDescription: String? {
        switch self {
        case .missingResultArtifact: "Video analyzer did not return exactly one result artifact."
        case .malformedResultArtifact: "Video analyzer returned an unreadable result artifact."
        case .taskIDMismatch: "Video analyzer result belongs to a different task."
        case .unsupportedSchemaVersion(let version): "Unsupported video analysis schema version: \(version)"
        case .invalidFileArtifact: "Video analyzer returned an invalid result file."
        case .invalidNestedAsset: "Video analyzer returned an invalid frame or report file."
        }
    }
}

public enum VideoAnalysisPluginResultDecoder {
    public static func decode(
        from events: [PluginOutputEvent],
        expectedTaskID: UUID
    ) throws -> VideoAnalysisResult {
        let artifact = try uniqueArtifact(in: events)
        guard case .inline(let content) = artifact.payload else {
            throw VideoAnalysisPluginResultError.malformedResultArtifact
        }
        return try decodedResult(Data(content.utf8), expectedTaskID: expectedTaskID)
    }

    public static func decode(
        from events: [PluginOutputEvent],
        expectedTaskID: UUID,
        expectedOutputDirectory: URL
    ) throws -> VideoAnalysisResult {
        let artifact = try uniqueArtifact(in: events)
        switch artifact.payload {
        case .inline(let content):
            return try decodedResult(Data(content.utf8), expectedTaskID: expectedTaskID)
        case .file(let file):
            guard file.mediaType == "application/json" else {
                throw VideoAnalysisPluginResultError.malformedResultArtifact
            }
            let reader: ConfinedArtifactReader
            let data: Data
            do {
                reader = try ConfinedArtifactReader(root: expectedOutputDirectory)
                data = try reader.read(file)
            } catch let error as ConfinedArtifactError {
                throw VideoAnalysisPluginResultError.invalidFileArtifact(error)
            }
            let result = try decodedResult(data, expectedTaskID: expectedTaskID)
            return try normalizeAssets(in: result, reader: reader)
        }
    }

    private static func uniqueArtifact(in events: [PluginOutputEvent]) throws -> PluginArtifact {
        let artifacts = events.flatMap { event -> [PluginArtifact] in
            guard case .result(_, _, _, let artifacts) = event else { return [] }
            return artifacts.filter { $0.type == "videoAnalysisResult" }
        }
        guard artifacts.count == 1, let artifact = artifacts.first else {
            throw VideoAnalysisPluginResultError.missingResultArtifact
        }
        return artifact
    }

    private static func decodedResult(_ data: Data, expectedTaskID: UUID) throws -> VideoAnalysisResult {
        let result: VideoAnalysisResult
        do {
            result = try JSONDecoder.openFinder.decode(VideoAnalysisResult.self, from: data)
        } catch {
            throw VideoAnalysisPluginResultError.malformedResultArtifact
        }
        guard result.schemaVersion == 1 else {
            throw VideoAnalysisPluginResultError.unsupportedSchemaVersion(result.schemaVersion)
        }
        guard result.taskID == expectedTaskID else {
            throw VideoAnalysisPluginResultError.taskIDMismatch
        }
        return result
    }

    private static func normalizeAssets(
        in result: VideoAnalysisResult,
        reader: ConfinedArtifactReader
    ) throws -> VideoAnalysisResult {
        do {
            let videos = try result.videos.map { video in
                let frames = try video.frames.map { frame in
                    let url = try reader.validate(relativePath: frame.imagePath)
                    return VideoFrameAnalysis(
                        index: frame.index, timestamp: frame.timestamp, imagePath: url.path,
                        faceVisible: frame.faceVisible, faceCount: frame.faceCount,
                        nudityLevel: frame.nudityLevel, summary: frame.summary, tags: frame.tags
                    )
                }
                let reportPath = try video.reportPath.map { try reader.validate(relativePath: $0).path }
                return AnalyzedVideo(
                    path: video.path, name: video.name, summary: video.summary, frames: frames,
                    suggestedTags: video.suggestedTags, reportPath: reportPath
                )
            }
            return .init(schemaVersion: result.schemaVersion, taskID: result.taskID, videos: videos)
        } catch let error as ConfinedArtifactError {
            throw VideoAnalysisPluginResultError.invalidNestedAsset(error)
        }
    }
}
