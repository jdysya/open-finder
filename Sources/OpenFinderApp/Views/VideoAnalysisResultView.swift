import OpenFinderCore
import SwiftUI

struct VideoAnalysisResultView: View {
    let result: VideoAnalysisResult
    let onApplyTags: (VideoAnalysisResult) async -> String
    let onDismiss: () -> Void
    @State private var isApplying = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Video Analysis")
                .font(.title2)
            List(result.videos, id: \.path) { video in
                VStack(alignment: .leading, spacing: 5) {
                    Text(video.name)
                        .font(.headline)
                    Text("\(video.summary.totalFrames) frames, \(video.summary.faceVisible) with faces, \(video.summary.explicit) explicit")
                        .foregroundStyle(.secondary)
                    if !video.suggestedTags.isEmpty {
                        Text(video.suggestedTags.map(\.name).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let reportPath = video.reportPath {
                        Text(reportPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Close", action: onDismiss)
                Button("Apply Suggested Tags") {
                    Task {
                        isApplying = true
                        message = await onApplyTags(result)
                        isApplying = false
                    }
                }
                .disabled(isApplying || result.videos.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
    }
}
