import Foundation

public struct MediaFacetSelection: Hashable, Sendable {
    public let key: String
    public let value: MediaFacetValue

    public init(key: String, value: MediaFacetValue) {
        self.key = key
        self.value = value
    }
}

public struct MediaFacetPresentation: Hashable, Sendable {
    public let selection: MediaFacetSelection
    public let label: String
    public let category: String
    public let momentCount: Int
    public let totalMoments: Int

    public init(
        selection: MediaFacetSelection,
        label: String,
        category: String,
        momentCount: Int,
        totalMoments: Int
    ) {
        self.selection = selection
        self.label = label
        self.category = category
        self.momentCount = momentCount
        self.totalMoments = totalMoments
    }
}

public struct MediaAnalysisTagSelection: Hashable, Sendable {
    public let stableMediaID: String
    public let selectedNames: Set<String>

    public init(stableMediaID: String, selectedNames: Set<String>) {
        self.stableMediaID = stableMediaID
        self.selectedNames = selectedNames
    }
}

public struct MediaAnalysisPresentationService: Sendable {
    public init() {}

    public func summary(for item: MediaAnalysisItem) -> [MediaSummaryMetric] {
        item.summaryMetrics
    }

    public func facets(for item: MediaAnalysisItem) -> [MediaFacetPresentation] {
        var counts: [MediaFacetSelection: Int] = [:]
        for moment in item.moments {
            for selection in selections(for: moment) {
                counts[selection, default: 0] += 1
            }
        }
        return counts.map { selection, count in
            .init(
                selection: selection,
                label: label(for: selection),
                category: category(for: selection),
                momentCount: count,
                totalMoments: item.moments.count
            )
        }
        .sorted {
            if $0.category != $1.category {
                return $0.category.localizedStandardCompare($1.category) == .orderedAscending
            }
            if $0.momentCount != $1.momentCount {
                return $0.momentCount > $1.momentCount
            }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    public func moments(
        in item: MediaAnalysisItem,
        matching selections: Set<MediaFacetSelection>
    ) -> [MediaAnalysisMoment] {
        guard !selections.isEmpty else { return item.moments }
        return item.moments.filter { moment in
            let available = self.selections(for: moment)
            return selections.isSubset(of: available)
        }
    }

    public func suggestedTags(
        in item: MediaAnalysisItem,
        selectedNames: Set<String>
    ) -> [MediaSuggestedTag] {
        item.suggestedTags.filter { selectedNames.contains($0.name) }
    }

    public func displayValue(_ value: MediaFacetValue) -> String {
        switch value {
        case .bool(let value): value ? "是" : "否"
        case .integer(let value): String(value)
        case .number(let value): value.formatted()
        case .text(let value): value
        }
    }

    private static let suggestedTagKeyPrefix = "$suggestedTag/"

    private func selections(for moment: MediaAnalysisMoment) -> Set<MediaFacetSelection> {
        let facets = moment.facets.map {
            MediaFacetSelection(key: $0.key, value: $0.value)
        }
        let tags = moment.suggestedTags.map {
            MediaFacetSelection(
                key: Self.suggestedTagKeyPrefix + $0.source + "/" + $0.category,
                value: .text($0.name)
            )
        }
        return Set(facets + tags)
    }

    private func label(for selection: MediaFacetSelection) -> String {
        switch (selection.key, selection.value) {
        case ("faceVisible", .bool(let visible)):
            visible ? "露脸" : "不露脸"
        case ("faceCount", .integer(let count)):
            count == 0 ? "无人脸" : "\(count) 张人脸"
        case ("nudityLevel", .text(let level)):
            nudityLabel(level)
        case (let key, _) where key.hasPrefix(Self.suggestedTagKeyPrefix):
            displayValue(selection.value)
        default:
            "\(selection.key)：\(displayValue(selection.value))"
        }
    }

    private func category(for selection: MediaFacetSelection) -> String {
        switch selection.key {
        case "faceVisible":
            "人脸可见性"
        case "faceCount":
            "人脸数量"
        case "nudityLevel":
            "裸露程度"
        case let key where key.hasPrefix(Self.suggestedTagKeyPrefix):
            suggestedTagCategory(from: key)
        default:
            selection.key
        }
    }

    private func nudityLabel(_ value: String) -> String {
        switch value {
        case "none": "完全穿着"
        case "partial": "部分裸露"
        case "moderate": "中度裸露"
        case "explicit": "完全裸露"
        case "unknown": "未知"
        default: value
        }
    }

    private func suggestedTagCategory(from key: String) -> String {
        let components = key
            .dropFirst(Self.suggestedTagKeyPrefix.count)
            .split(separator: "/", maxSplits: 1)
            .map(String.init)
        let source = components.first.map {
            $0.caseInsensitiveCompare("joytag") == .orderedSame ? "JoyTag" : $0
        } ?? "分析标签"
        let category = components.count == 2 ? localizedTagCategory(components[1]) : nil
        return [source, category].compactMap { $0 }.joined(separator: " · ")
    }

    private func localizedTagCategory(_ category: String) -> String {
        switch category.lowercased() {
        case "adult": "成人内容"
        case "scene": "场景"
        default: category
        }
    }
}
