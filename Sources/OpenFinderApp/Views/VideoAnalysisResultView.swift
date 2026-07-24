import OpenFinderCore
import SwiftUI

struct VideoAnalysisResultView: View {
    let result: VideoAnalysisResult
    let onApplyTags: ([VideoAnalysisTagSelection]) async -> String
    let onDismiss: () -> Void

    @State private var selectedVideoPath: String?
    @State private var filtersByVideo: [String: Set<String>] = [:]
    @State private var finderTagsByVideo: [String: Set<String>] = [:]
    @State private var previewFrameIndex: Int?
    @State private var isApplying = false
    @State private var message: String?

    init(
        result: VideoAnalysisResult,
        onApplyTags: @escaping ([VideoAnalysisTagSelection]) async -> String,
        onDismiss: @escaping () -> Void
    ) {
        self.result = result
        self.onApplyTags = onApplyTags
        self.onDismiss = onDismiss
        _selectedVideoPath = State(initialValue: result.videos.first?.path)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedVideoPath) {
                ForEach(result.videos, id: \.path) { video in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.name)
                            .lineLimit(2)
                        Text("\(video.frames.count) 个关键帧")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(video.path)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(MediaPresentationSemantics.mediaAccessibilityLabel(
                        name: video.name,
                        keyframeCount: video.frames.count
                    ))
                }
            }
            .navigationTitle("视频")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            if let video = selectedVideo {
                VStack(spacing: 0) {
                    VideoAnalysisWorkspaceView(
                        video: video,
                        filters: filtersBinding(for: video.path),
                        finderTags: finderTagsBinding(for: video.path),
                        previewFrameIndex: $previewFrameIndex
                    )
                    Divider()
                    footer
                }
                .navigationTitle(video.name)
            } else {
                ContentUnavailableView(MediaPresentationSemantics.emptyTitle, systemImage: "film")
            }
        }
        .frame(minWidth: 960, idealWidth: 1120, minHeight: 640, idealHeight: 760)
        .onChange(of: selectedVideoPath) { _, _ in
            previewFrameIndex = nil
            message = nil
        }
        .sheet(isPresented: Binding(
            get: { previewFrameIndex != nil },
            set: { if !$0 { previewFrameIndex = nil } }
        )) {
            if let video = selectedVideo,
               let frame = filteredFrames(for: video).first(where: { $0.index == previewFrameIndex }) {
                KeyframePreviewView(
                    frame: frame,
                    frames: filteredFrames(for: video),
                    previewFrameIndex: $previewFrameIndex
                )
            }
        }
    }

    private var selectedVideo: AnalyzedVideo? {
        let path = MediaPresentationSemantics.selectedPath(
            in: result.videos.map(\.path),
            requested: selectedVideoPath
        )
        return result.videos.first { $0.path == path }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text("已选择 \(finderTagCount) 个 Finder 标签")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(MediaPresentationSemantics.closeTitle, action: onDismiss)
                .keyboardShortcut(.cancelAction)
            Button("应用 Finder 标签选择") {
                Task {
                    isApplying = true
                    message = await onApplyTags(tagSelections)
                    isApplying = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isApplying || finderTagCount == 0)
        }
        .padding(12)
        .background(.bar)
    }

    private var finderTagCount: Int {
        finderTagsByVideo.values.reduce(0) { $0 + $1.count }
    }

    private var tagSelections: [VideoAnalysisTagSelection] {
        result.videos.map {
            .init(videoPath: $0.path, selectedNames: finderTagsByVideo[$0.path, default: []])
        }
    }

    private func filtersBinding(for path: String) -> Binding<Set<String>> {
        Binding(
            get: { filtersByVideo[path, default: []] },
            set: { filtersByVideo[path] = $0 }
        )
    }

    private func finderTagsBinding(for path: String) -> Binding<Set<String>> {
        Binding(
            get: { finderTagsByVideo[path, default: []] },
            set: { finderTagsByVideo[path] = $0 }
        )
    }

    private func filteredFrames(for video: AnalyzedVideo) -> [VideoFrameAnalysis] {
        VideoAnalysisPresentation.frames(
            in: video,
            matching: filtersByVideo[video.path, default: []]
        )
    }
}
