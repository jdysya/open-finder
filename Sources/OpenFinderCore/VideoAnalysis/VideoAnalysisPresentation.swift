import Foundation

public struct VideoAnalysisTagFacet: Hashable, Sendable {
    public let label: String
    public let category: String
    public let frameCount: Int
    public let totalFrames: Int

    public var ratio: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(frameCount) / Double(totalFrames)
    }
}

public struct VideoAnalysisTagSelection: Hashable, Sendable {
    public let videoPath: String
    public let selectedNames: Set<String>

    public init(videoPath: String, selectedNames: Set<String>) {
        self.videoPath = videoPath
        self.selectedNames = selectedNames
    }
}

public enum VideoAnalysisPresentation {
    public static func facets(for video: AnalyzedVideo) -> [VideoAnalysisTagFacet] {
        var counts: [FacetIdentity: Int] = [:]
        for frame in video.frames {
            for identity in identities(for: frame) {
                counts[identity, default: 0] += 1
            }
        }
        return counts.map { identity, count in
            .init(label: identity.label, category: identity.category, frameCount: count, totalFrames: video.frames.count)
        }.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            if $0.frameCount != $1.frameCount { return $0.frameCount > $1.frameCount }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    public static func frames(in video: AnalyzedVideo, matching labels: Set<String>) -> [VideoFrameAnalysis] {
        guard !labels.isEmpty else { return video.frames }
        return video.frames.filter { frame in
            let available = Set(identities(for: frame).map(\.label))
            return labels.isSubset(of: available)
        }
    }

    public static func labels(for frame: VideoFrameAnalysis) -> [String] {
        identities(for: frame).map(\.label)
    }

    public static func finderTagSuggestions(
        in video: AnalyzedVideo,
        selectedNames: Set<String>
    ) -> [VideoAnalysisTagSuggestion] {
        video.suggestedTags.filter { selectedNames.contains($0.name) }
    }

    private struct FacetIdentity: Hashable {
        let category: String
        let label: String
    }

    private static func identities(for frame: VideoFrameAnalysis) -> Set<FacetIdentity> {
        var result: Set<FacetIdentity> = [
            .init(category: "露脸", label: frame.faceVisible ? "露脸" : "不露脸"),
            .init(category: "裸露程度", label: nudityLabel(frame.nudityLevel)),
        ]
        result.formUnion(frame.tags.map { .init(category: $0.category, label: $0.name) })
        return result
    }

    private static func nudityLabel(_ level: VideoNudityLevel) -> String {
        switch level {
        case .none: "完全穿着"
        case .partial: "部分裸露"
        case .moderate: "中度裸露"
        case .explicit: "完全裸露"
        case .unknown: "未知"
        }
    }
}
