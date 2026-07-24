import AppKit
import OpenFinderCore
import SwiftUI

struct MediaAnalysisMomentSection: View {
    let item: MediaAnalysisItem
    let moments: [MediaAnalysisMoment]
    let artifactURL: @Sendable (UUID) async -> URL?
    let resolvedAssetURL: (ConfinedAssetReference) -> URL?
    @Binding var previewMomentIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("分析时刻")
                    .font(.headline)
                Text("\(moments.count) / \(item.moments.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if moments.isEmpty {
                ContentUnavailableView(
                    "没有匹配的分析时刻",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("清除部分筛选条件后重试。")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(moments, id: \.index) { moment in
                        MediaAnalysisMomentCard(
                            moment: moment,
                            artifactURL: artifactURL,
                            resolvedAssetURL: resolvedAssetURL
                        ) {
                            previewMomentIndex = moment.index
                        }
                    }
                }
            }
        }
    }
}

private struct MediaAnalysisMomentCard: View {
    let moment: MediaAnalysisMoment
    let artifactURL: @Sendable (UUID) async -> URL?
    let resolvedAssetURL: (ConfinedAssetReference) -> URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                MediaAnalysisAssetImage(
                    reference: moment.assets.first,
                    artifactURL: artifactURL,
                    resolvedAssetURL: resolvedAssetURL
                )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text(MediaAnalysisFormatting.timestamp(moment.timestamp))
                        .font(.caption.monospacedDigit().weight(.medium))
                    Spacer()
                }
                Text(moment.summary.isEmpty ? "无时刻摘要" : moment.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(moment.facets.prefix(4).map {
                    "\($0.key): \(MediaAnalysisPresentationService().displayValue($0.value))"
                }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .accessibilityLabel(MediaPresentationSemantics.frameAccessibilityLabel(
            timestamp: MediaAnalysisFormatting.timestamp(moment.timestamp),
            summary: moment.summary
        ))
    }
}

struct MediaAnalysisMomentPreviewView: View {
    let moment: MediaAnalysisMoment
    let moments: [MediaAnalysisMoment]
    let artifactURL: @Sendable (UUID) async -> URL?
    let resolvedAssetURL: (ConfinedAssetReference) -> URL?
    @Binding var previewMomentIndex: Int?

    private var position: Int? {
        moments.firstIndex(where: { $0.index == moment.index })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaAnalysisAssetImage(
                reference: moment.assets.first,
                artifactURL: artifactURL,
                resolvedAssetURL: resolvedAssetURL
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button {
                    movePreview(by: -1)
                } label: {
                    Label("上一帧", systemImage: "chevron.left")
                }
                .disabled(position == nil || position == moments.startIndex)
                Button {
                    movePreview(by: 1)
                } label: {
                    Label("下一帧", systemImage: "chevron.right")
                }
                .disabled(position == nil || position == moments.index(before: moments.endIndex))
                Spacer()
                Text(MediaAnalysisFormatting.timestamp(moment.timestamp))
                    .font(.headline.monospacedDigit())
                Button(MediaPresentationSemantics.closeTitle) { previewMomentIndex = nil }
                    .keyboardShortcut(.cancelAction)
            }
            Text(moment.summary)
            Text(moment.facets.map {
                "\($0.key): \(MediaAnalysisPresentationService().displayValue($0.value))"
            }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func movePreview(by offset: Int) {
        guard let destination = MediaPresentationSemantics.previewIndex(
            from: previewMomentIndex,
            offset: offset,
            available: moments.map(\.index)
        ) else {
            return
        }
        previewMomentIndex = destination
    }
}

private struct MediaAnalysisAssetImage: View {
    let reference: ConfinedAssetReference?
    let artifactURL: @Sendable (UUID) async -> URL?
    let resolvedAssetURL: (ConfinedAssetReference) -> URL?

    @State private var image: NSImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if !didLoad {
                ProgressView()
            } else {
                ContentUnavailableView("缩略图不可用", systemImage: "photo")
            }
        }
        .background(.black.opacity(0.08))
        .accessibilityLabel("媒体分析时刻预览")
        .task(id: reference) {
            defer { didLoad = true }
            guard let reference else { return }
            if let url = resolvedAssetURL(reference) {
                image = NSImage(contentsOf: url)
                return
            }
            guard let url = await artifactURL(reference.artifactID) else { return }
            image = NSImage(contentsOf: url)
        }
    }
}

private enum MediaAnalysisFormatting {
    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(
            format: "%02d:%02d:%02d",
            total / 3_600,
            (total % 3_600) / 60,
            total % 60
        )
    }
}
