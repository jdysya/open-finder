import OpenFinderCore
import SwiftUI

enum MediaPresentationSemantics {
    static let emptyTitle = "没有分析结果"
    static let closeTitle = "关闭"

    static func selectedPath(in paths: [String], requested: String?) -> String? {
        paths.first { $0 == requested } ?? paths.first
    }

    static func previewIndex(
        from current: Int?,
        offset: Int,
        available indices: [Int]
    ) -> Int? {
        guard let current,
              let position = indices.firstIndex(of: current)
        else {
            return nil
        }
        let destination = position + offset
        guard indices.indices.contains(destination) else { return nil }
        return indices[destination]
    }

    static func mediaAccessibilityLabel(name: String, keyframeCount: Int) -> String {
        "\(name)，\(keyframeCount) 个关键帧"
    }

    static func frameAccessibilityLabel(timestamp: String, summary: String) -> String {
        "\(timestamp)，\(summary)"
    }
}

struct ContentView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DualPaneView()
            Divider()
            TaskQueueView(
                records: app.taskRecords,
                logs: app.taskLogs,
                statusMessage: app.statusMessage,
                onCancel: { app.cancelTask($0) },
                onRetry: { app.retryTask($0) },
                onCopyLogs: { app.copyLogs(for: $0) }
            )
            .frame(height: app.taskRecords.isEmpty ? 120 : 240)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { app.activeBrowser.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!app.activeBrowser.canGoBack)
                    .help("Back")
                Button { app.activeBrowser.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!app.activeBrowser.canGoForward)
                    .help("Forward")
                Button { app.activeBrowser.goUp() } label: { Image(systemName: "arrow.up") }
                    .help("Parent Directory")
                Button { Task { await app.activeBrowser.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Divider()
                Button { app.activeBrowser.createFile() } label: { Image(systemName: "doc.badge.plus") }
                    .help("New File")
                Button { app.activeBrowser.createFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .help("New Folder")
                Button { app.copySelectionToOtherPane(move: false) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy selected items to the other pane")
                Button { app.copySelectionToOtherPane(move: true) } label: { Image(systemName: "arrow.right.doc.on.clipboard") }
                    .help("Move selected items to the other pane")
                Divider()
                Button { app.activeBrowser.toggleHidden() } label: { Image(systemName: app.activeBrowser.showHiddenFiles ? "eye.slash" : "eye") }
                    .help("Show or hide hidden files")
                Button { app.quickLookSelected() } label: { Image(systemName: "quicklook") }
                    .help("Quick Look")
            }
        }
        .alert(item: $app.pendingTransferOverwrite) { pending in
            Alert(
                title: Text("覆盖同名项目？"),
                message: Text(pending.message),
                primaryButton: .destructive(Text("覆盖")) { app.confirmPendingTransferOverwrite(pending) },
                secondaryButton: .cancel(Text("取消")) { app.cancelPendingTransferOverwrite() }
            )
        }
        .sheet(isPresented: Binding(
            get: { app.presentedVideoAnalysis != nil },
            set: { if !$0 { app.dismissVideoAnalysis() } }
        )) {
            if let result = app.presentedVideoAnalysis {
                VideoAnalysisResultView(
                    result: result,
                    onApplyTags: { selections in
                        await app.applySelectedVideoTags(selections, from: result)
                    },
                    onDismiss: { app.dismissVideoAnalysis() }
                )
            }
        }
        .task { await app.loadInitialState() }
    }
}

struct DualPaneView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HSplitView {
            FilePaneView(pane: app.leftPane, isActive: app.activePane == .left)
                .frame(minWidth: 320)
            FilePaneView(pane: app.rightPane, isActive: app.activePane == .right)
                .frame(minWidth: 320)
        }
    }
}
