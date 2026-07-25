import OpenFinderCore
import SwiftUI

struct MediaAnalysisWorkspaceView: View {
    let item: MediaAnalysisItem
    let artifactURL: @Sendable (UUID) async -> URL?
    let resolvedAssetURL: (ConfinedAssetReference) -> URL?
    @Binding var filters: Set<MediaFacetSelection>
    @Binding var finderTags: Set<String>
    @Binding var previewMomentIndex: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryHeader
                Divider()
                filterSection
                Divider()
                MediaAnalysisMomentSection(
                    item: item,
                    moments: filteredMoments,
                    artifactURL: artifactURL,
                    resolvedAssetURL: resolvedAssetURL,
                    previewMomentIndex: $previewMomentIndex
                )
                Divider()
                finderTagSection
            }
            .padding(20)
        }
    }

    private let presentation = MediaAnalysisPresentationService()

    private var filteredMoments: [MediaAnalysisMoment] {
        presentation.moments(in: item, matching: filters)
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.media.displayName)
                .font(.title2.weight(.semibold))
            Text(item.media.sourcePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(item.media.sourcePath)
            HStack(spacing: 16) {
                ForEach(presentation.summary(for: item), id: \.key) { metric in
                    SummaryValue(formatted(metric), label: metric.key)
                }
            }
        }
    }

    private var filterSection: some View {
        let facets = presentation.facets(for: item)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("关键帧筛选")
                        .font(.headline)
                    Text("按人脸、裸露程度和 JoyTag 标签筛选下方关键帧；多个条件需同时满足，不会写入 Finder 标签。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !filters.isEmpty {
                    Button("清除筛选") {
                        filters = []
                    }
                }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(facets, id: \.self) { facet in
                    Button {
                        toggleFilter(facet.selection)
                    } label: {
                        HStack(spacing: 6) {
                            Text(facet.label).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(facet.momentCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(filters.contains(facet.selection) ? .accentColor : nil)
                    .help("\(facet.category) · \(facet.momentCount)/\(facet.totalMoments) 个时刻")
                    .accessibilityLabel(
                        "\(facet.category)，\(facet.label)，\(facet.momentCount) 个时刻"
                    )
                }
            }
        }
    }

    private var finderTagSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("写入 Finder 的标签")
                .font(.headline)
            Text("与上方筛选相互独立。仅勾选的建议标签会参与 Finder 双向同步。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if item.suggestedTags.isEmpty {
                Text("分析器没有为此媒体生成建议标签。")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(item.suggestedTags, id: \.name) { tag in
                        Toggle(isOn: Binding(
                            get: { finderTags.contains(tag.name) },
                            set: { setFinderTag(tag.name, selected: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tag.name).lineLimit(1)
                                Text("置信度 \(tag.confidence, format: .percent.precision(.fractionLength(0)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private func toggleFilter(_ selection: MediaFacetSelection) {
        if filters.contains(selection) {
            filters.remove(selection)
        } else {
            filters.insert(selection)
        }
        previewMomentIndex = nil
    }

    private func setFinderTag(_ name: String, selected: Bool) {
        if selected {
            finderTags.insert(name)
        } else {
            finderTags.remove(name)
        }
    }

    private func formatted(_ metric: MediaSummaryMetric) -> String {
        switch metric.unit {
        case .count: Int(metric.value).formatted()
        case .ratio: metric.value.formatted(.percent)
        case .seconds: metric.value.formatted() + " 秒"
        case .score: metric.value.formatted(.number.precision(.fractionLength(2)))
        }
    }
}

private struct SummaryValue: View {
    let value: String
    let label: String

    init(_ value: String, label: String) {
        self.value = value
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
