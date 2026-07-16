import OpenFinderCore
import SwiftUI

struct VideoAnalysisWorkspaceView: View {
    let video: AnalyzedVideo
    @Binding var filters: Set<String>
    @Binding var finderTags: Set<String>
    @Binding var previewFrameIndex: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryHeader
                Divider()
                filterSection
                Divider()
                VideoAnalysisKeyframeSection(
                    video: video,
                    frames: filteredFrames,
                    previewFrameIndex: $previewFrameIndex
                )
                Divider()
                finderTagSection
            }
            .padding(20)
        }
    }

    private var filteredFrames: [VideoFrameAnalysis] {
        VideoAnalysisPresentation.frames(in: video, matching: filters)
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(video.name)
                .font(.title2.weight(.semibold))
            Text(video.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(video.path)
            HStack(spacing: 16) {
                SummaryValue("\(video.summary.totalFrames)", label: "关键帧")
                SummaryValue("\(video.summary.faceVisible)", label: "露脸")
                SummaryValue("\(video.summary.explicit)", label: "完全裸露")
                SummaryValue("\(video.summary.partial + video.summary.moderate)", label: "部分或中度")
            }
        }
    }

    private var filterSection: some View {
        let facets = VideoAnalysisPresentation.facets(for: video)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("分析筛选")
                        .font(.headline)
                    Text("仅筛选下方关键帧，不会写入 Finder 标签。多个条件同时满足时才显示。")
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
                        toggleFilter(facet.label)
                    } label: {
                        HStack(spacing: 6) {
                            Text(facet.label).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(facet.frameCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(filters.contains(facet.label) ? .accentColor : nil)
                    .help("\(facet.category) · \(facet.frameCount)/\(facet.totalFrames) 帧")
                    .accessibilityLabel("\(facet.category)，\(facet.label)，\(facet.frameCount) 帧")
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
            if video.suggestedTags.isEmpty {
                Text("分析器没有为此视频生成建议标签。")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(video.suggestedTags, id: \.name) { tag in
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

    private func toggleFilter(_ label: String) {
        if filters.contains(label) {
            filters.remove(label)
        } else {
            filters.insert(label)
        }
        previewFrameIndex = nil
    }

    private func setFinderTag(_ name: String, selected: Bool) {
        if selected {
            finderTags.insert(name)
        } else {
            finderTags.remove(name)
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
