import OpenFinderCore
import SwiftUI

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
            .frame(minHeight: 120, idealHeight: 150, maxHeight: 220)
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
        .task { await app.loadInitialState() }
    }
}

struct DualPaneView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HSplitView {
            FilePaneView(pane: app.leftPane, isActive: app.activePane == .left)
                .onTapGesture { app.activePane = .left }
                .frame(minWidth: 320)
            FilePaneView(pane: app.rightPane, isActive: app.activePane == .right)
                .onTapGesture { app.activePane = .right }
                .frame(minWidth: 320)
        }
    }
}
