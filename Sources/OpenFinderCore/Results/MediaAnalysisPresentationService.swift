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
    public let momentCount: Int
    public let totalMoments: Int

    public init(
        selection: MediaFacetSelection,
        momentCount: Int,
        totalMoments: Int
    ) {
        self.selection = selection
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
            for facet in Set(moment.facets) {
                counts[.init(key: facet.key, value: facet.value), default: 0] += 1
            }
        }
        return counts.map { selection, count in
            .init(
                selection: selection,
                momentCount: count,
                totalMoments: item.moments.count
            )
        }
        .sorted {
            if $0.selection.key != $1.selection.key {
                return $0.selection.key.localizedStandardCompare($1.selection.key) == .orderedAscending
            }
            if $0.momentCount != $1.momentCount {
                return $0.momentCount > $1.momentCount
            }
            return displayValue($0.selection.value)
                .localizedStandardCompare(displayValue($1.selection.value)) == .orderedAscending
        }
    }

    public func moments(
        in item: MediaAnalysisItem,
        matching selections: Set<MediaFacetSelection>
    ) -> [MediaAnalysisMoment] {
        guard !selections.isEmpty else { return item.moments }
        return item.moments.filter { moment in
            let available = Set(moment.facets.map {
                MediaFacetSelection(key: $0.key, value: $0.value)
            })
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
}
