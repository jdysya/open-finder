import OpenFinderCore
import SwiftUI

struct FilePaneView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var pane: BrowserPaneModel
    let isActive: Bool
    @State private var renameText = ""
    @State private var showingRename = false

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            FileTableRepresentable(
                items: pane.visibleItems,
                selection: $pane.selection,
                onOpen: { pane.open($0) },
                onActivate: { app.activePane = pane.id },
                onDropFileURLs: { app.dropLocalFileURLs($0, into: pane) },
                pluginActionsForSelection: { app.pluginActions(for: $0) },
                onAction: handleTableAction
            )
            .background(.regularMaterial)
            if let error = pane.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .overlay(alignment: .top) {
            if isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .alert("Delete remote item permanently?", isPresented: Binding(
            get: { pane.pendingDeletion != nil },
            set: { if !$0 { pane.cancelPendingDeletion() } }
        )) {
            Button("Delete", role: .destructive) { pane.confirmPendingDeletion() }
            Button("Cancel", role: .cancel) { pane.cancelPendingDeletion() }
        } message: {
            Text("WebDAV does not provide Trash semantics here. This will permanently delete the selected remote item(s).")
        }
        .alert("Rename", isPresented: $showingRename) {
            TextField("New name", text: $renameText)
            Button("Rename") { pane.renameFirstSelected(to: renameText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new name for the selected item.")
        }
    }

    private var pathBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label(pane.id.rawValue.capitalized, systemImage: isActive ? "rectangle.inset.filled" : "rectangle")
                    .font(.headline)
                    .foregroundStyle(isActive ? .primary : .secondary)
                Text(pane.location.displayPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                if pane.isLoading { ProgressView().controlSize(.small) }
                Menu("Plugins") {
                    let actions = app.pluginActions(for: pane.selectedItems)
                    if actions.isEmpty {
                        Text("No matching actions")
                    } else {
                        ForEach(actions, id: \.1.id) { plugin, action in
                            Button("\(plugin.manifest.name): \(action.title)") {
                                app.runPlugin(plugin, action: action, items: pane.selectedItems, pane: pane)
                            }
                        }
                    }
                }
                .disabled(pane.selectedItems.isEmpty)
            }
            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $pane.filterText)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(8)
        .background(.bar)
    }

    private func handleTableAction(_ action: FileTableAction, _ items: [FileItem]) {
        app.activePane = pane.id
        switch action {
        case .open:
            if let item = items.first { pane.open(item) }
        case .rename:
            renameText = items.first?.name ?? ""
            showingRename = true
        case .trash:
            pane.trashSelected()
        case .revealInFinder:
            pane.revealSelectedInFinder()
        case .openInTerminal:
            pane.openSelectedInTerminal()
        case .quickLook:
            pane.quickLookSelected()
        case .copyToOtherPane:
            app.copySelectionToOtherPane(move: false)
        case .moveToOtherPane:
            app.copySelectionToOtherPane(move: true)
        case .goBack:
            pane.goBack()
        case .goForward:
            pane.goForward()
        case .goUp:
            pane.goUp()
        case .refresh:
            Task { await pane.refresh() }
        case .toggleHidden:
            pane.toggleHidden()
        case .createFile:
            pane.createFile()
        case .createFolder:
            pane.createFolder()
        case .plugin(let plugin, let action):
            app.runPlugin(plugin, action: action, items: items, pane: pane)
        }
    }
}
