import AppKit
import OpenFinderCore
import SwiftUI

struct VideoAnalysisKeyframeSection: View {
    let video: AnalyzedVideo
    let frames: [VideoFrameAnalysis]
    @Binding var previewFrameIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("关键帧")
                    .font(.headline)
                Text("\(frames.count) / \(video.frames.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if frames.isEmpty {
                ContentUnavailableView(
                    "没有匹配的关键帧",
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
                    ForEach(frames, id: \.index) { frame in
                        KeyframeCard(frame: frame) {
                            previewFrameIndex = frame.index
                        }
                    }
                }
            }
        }
    }
}

private struct KeyframeCard: View {
    let frame: VideoFrameAnalysis
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                KeyframeImage(path: frame.imagePath)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text(VideoAnalysisFormatting.timestamp(frame.timestamp))
                        .font(.caption.monospacedDigit().weight(.medium))
                    Spacer()
                    if frame.faceVisible {
                        Label("\(frame.faceCount)", systemImage: "person.crop.rectangle")
                            .font(.caption)
                    }
                }
                Text(frame.summary.isEmpty ? "无帧摘要" : frame.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(VideoAnalysisPresentation.labels(for: frame).prefix(4).joined(separator: " · "))
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
            timestamp: VideoAnalysisFormatting.timestamp(frame.timestamp),
            summary: frame.summary
        ))
    }
}

struct KeyframePreviewView: View {
    let frame: VideoFrameAnalysis
    let frames: [VideoFrameAnalysis]
    @Binding var previewFrameIndex: Int?

    private var position: Int? {
        frames.firstIndex(where: { $0.index == frame.index })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyframeImage(path: frame.imagePath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button {
                    movePreview(by: -1)
                } label: {
                    Label("上一帧", systemImage: "chevron.left")
                }
                .disabled(position == nil || position == frames.startIndex)
                Button {
                    movePreview(by: 1)
                } label: {
                    Label("下一帧", systemImage: "chevron.right")
                }
                .disabled(position == nil || position == frames.index(before: frames.endIndex))
                Spacer()
                Text(VideoAnalysisFormatting.timestamp(frame.timestamp))
                    .font(.headline.monospacedDigit())
                Button(MediaPresentationSemantics.closeTitle) { previewFrameIndex = nil }
                    .keyboardShortcut(.cancelAction)
            }
            Text(frame.summary)
            Text(VideoAnalysisPresentation.labels(for: frame).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
    }

    private func movePreview(by offset: Int) {
        guard let destination = MediaPresentationSemantics.previewIndex(
            from: previewFrameIndex,
            offset: offset,
            available: frames.map(\.index)
        ) else {
            return
        }
        previewFrameIndex = destination
    }
}

private struct KeyframeImage: View {
    let path: String

    var body: some View {
        Group {
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ContentUnavailableView("缩略图不可用", systemImage: "photo")
            }
        }
        .background(.black.opacity(0.08))
        .accessibilityLabel("视频关键帧")
    }
}

private enum VideoAnalysisFormatting {
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
