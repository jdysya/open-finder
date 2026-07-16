import Darwin
import Foundation

extension VideoAnalysisResultStore {
    public func persistAssets(in result: VideoAnalysisResult) throws -> VideoAnalysisResult {
        try VideoAnalysisAssetPersistence(directory: directory).persistLegacy(result)
    }

    public func persistConfinedAssets(
        in result: VideoAnalysisResult,
        from reader: ConfinedArtifactReader
    ) throws -> VideoAnalysisResult {
        try VideoAnalysisAssetPersistence(directory: directory).persistConfined(result, reader: reader)
    }
}

struct VideoAnalysisAssetPersistence {
    let directory: URL

    func persistLegacy(_ result: VideoAnalysisResult) throws -> VideoAnalysisResult {
        let taskDirectory = assetDirectory(taskID: result.taskID)
        let videos = try result.videos.enumerated().map { videoIndex, video in
            let videoDirectory = taskDirectory.appendingPathComponent(String(format: "%04d", videoIndex))
            try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
            let frames = try video.frames.map { frame in
                let source = URL(fileURLWithPath: frame.imagePath)
                let destination = videoDirectory
                    .appendingPathComponent(String(format: "frame-%04d", frame.index))
                    .appendingPathExtension(source.pathExtension.isEmpty ? "jpg" : source.pathExtension)
                try copyReplacing(source, destination)
                return replacingPath(of: frame, with: destination.path)
            }
            let reportPath = try video.reportPath.map { path in
                let source = URL(fileURLWithPath: path)
                let destination = videoDirectory.appendingPathComponent("report").appendingPathExtension(source.pathExtension)
                try copyReplacing(source, destination)
                return destination.path
            }
            return replacingAssets(of: video, frames: frames, reportPath: reportPath)
        }
        return .init(schemaVersion: result.schemaVersion, taskID: result.taskID, videos: videos)
    }

    func persistConfined(
        _ result: VideoAnalysisResult,
        reader: ConfinedArtifactReader
    ) throws -> VideoAnalysisResult {
        let taskDirectory = assetDirectory(taskID: result.taskID)
        let videos = try result.videos.map { video in
            let frames = try video.frames.map { frame in
                let path = try persistConfinedPath(frame.imagePath, taskDirectory: taskDirectory, reader: reader)
                return replacingPath(of: frame, with: path)
            }
            let reportPath = try video.reportPath.map {
                try persistConfinedPath($0, taskDirectory: taskDirectory, reader: reader)
            }
            return replacingAssets(of: video, frames: frames, reportPath: reportPath)
        }
        return .init(schemaVersion: result.schemaVersion, taskID: result.taskID, videos: videos)
    }

    private func assetDirectory(taskID: UUID) -> URL {
        directory.appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
    }

    private func persistConfinedPath(
        _ path: String,
        taskDirectory: URL,
        reader: ConfinedArtifactReader
    ) throws -> String {
        let relativePath = try reader.relativePath(forValidatedURL: URL(fileURLWithPath: path))
        let destination = taskDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try reader.copy(relativePath: relativePath, to: temporary)
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw ConfinedArtifactError.ioFailure
        }
        return destination.path
    }

    private func copyReplacing(_ source: URL, _ destination: URL) throws {
        if source.standardizedFileURL.resolvingSymlinksInPath()
            == destination.standardizedFileURL.resolvingSymlinksInPath() { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func replacingPath(of frame: VideoFrameAnalysis, with path: String) -> VideoFrameAnalysis {
        .init(
            index: frame.index, timestamp: frame.timestamp, imagePath: path,
            faceVisible: frame.faceVisible, faceCount: frame.faceCount,
            nudityLevel: frame.nudityLevel, summary: frame.summary, tags: frame.tags
        )
    }

    private func replacingAssets(
        of video: AnalyzedVideo,
        frames: [VideoFrameAnalysis],
        reportPath: String?
    ) -> AnalyzedVideo {
        .init(
            path: video.path, name: video.name, summary: video.summary, frames: frames,
            suggestedTags: video.suggestedTags, reportPath: reportPath
        )
    }
}
