import OpenFinderCore
import SwiftUI

struct FilePaneView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var pane: BrowserPaneModel
    let isActive: Bool
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var pathDraft = ""
    @State private var pathSuggestions: [String] = []
    @State private var tagEditorContext: TagEditorContext?
    @FocusState private var isPathFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            FileTableRepresentable(
                items: pane.visibleItems,
                directorySizeText: pane.directorySizeText,
                selection: $pane.selection,
                onOpen: { pane.open($0) },
                onActivate: { app.activePane = pane.id },
                onDropFileURLs: { app.dropLocalFileURLs($0, into: pane) },
                remoteFileDownloader: { item, destination in
                    try await pane.downloadRemoteFile(item, to: destination)
                },
                pluginActionsForSelection: { app.pluginActions(for: $0) },
                presentationForAction: actionPresentation,
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
            Text("This remote provider does not provide Trash semantics here. This will permanently delete the selected remote item(s).")
        }
        .alert("Rename", isPresented: $showingRename) {
            TextField("New name", text: $renameText)
            Button("Rename") { pane.renameFirstSelected(to: renameText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new name for the selected item.")
        }
        .sheet(item: $tagEditorContext) { context in
            TagEditorView(
                context: context,
                onApply: { changes in
                    await pane.applyTagChanges(changes)
                    if context.errorMessage == nil {
                        tagEditorContext = nil
                    }
                },
                onRetry: { await pane.reloadTagCatalog() },
                onManage: { mutation in
                    let mutationSucceeded = await pane.mutateTagCatalog(mutation)
                    if mutationSucceeded {
                        await pane.reloadTagCatalog()
                    }
                    return mutationSucceeded
                },
                onDismiss: { tagEditorContext = nil }
            )
        }
        .onAppear { resetPathDraft() }
        .onChange(of: pane.location) { _, _ in resetPathDraft() }
    }

    private var pathBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label(pane.id.rawValue.capitalized, systemImage: isActive ? "rectangle.inset.filled" : "rectangle")
                    .font(.headline)
                    .foregroundStyle(isActive ? .primary : .secondary)
                TextField("Path", text: $pathDraft)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .focused($isPathFocused)
                    .onSubmit(commitPathDraft)
                    .onChange(of: pathDraft) { _, _ in updatePathSuggestions() }
                    .help("Edit path and press Return to jump")
                Spacer()
                if pane.isLoading { ProgressView().controlSize(.small) }
            }
            if isPathFocused && !pathSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("补全")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(pathSuggestions, id: \.self) { suggestion in
                            Button {
                                pathDraft = suggestion
                                commitPathDraft()
                            } label: {
                                Text(URL(fileURLWithPath: suggestion).lastPathComponent)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(suggestion)
                        }
                    }
                }
            }
            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $pane.filterText)
                    .textFieldStyle(.roundedBorder)
                if pane.selection.count > 1 {
                    Text("已选 \(pane.selection.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { app.activePane = pane.id }
    }

    private func resetPathDraft() {
        pathDraft = pane.location.displayPath
        updatePathSuggestions()
    }

    private func updatePathSuggestions() {
        guard case .local = pane.location, let baseURL = pane.location.localURL else {
            pathSuggestions = []
            return
        }
        pathSuggestions = LocalPathCompletion.suggestions(for: pathDraft, relativeTo: baseURL, limit: 6)
            .filter { $0 != LocalPathCompletion.resolvedPath(pathDraft, relativeTo: baseURL) }
    }

    private func commitPathDraft() {
        guard case .local = pane.location, let baseURL = pane.location.localURL else { return }
        let resolved = LocalPathCompletion.resolvedPath(pathDraft, relativeTo: baseURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            pane.errorMessage = "Path does not exist or is not a folder: \(resolved)"
            return
        }
        isPathFocused = false
        Task { await pane.navigate(to: .local(path: resolved)) }
    }

    private func handleTableAction(_ action: FileTableAction, _ items: [FileItem]) {
        app.activePane = pane.id
        switch action {
        case .open:
            if let item = items.first { pane.open(item) }
        case .editTags:
            Task {
                if let context = await pane.prepareTagEditor() {
                    tagEditorContext = context
                }
            }
        case .rename:
            guard items.count == 1, let item = items.first else { return }
            renameText = item.name
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
        case .selectAll:
            pane.selectAllVisible()
        case .plugin(let plugin, let action):
            app.runPlugin(plugin, action: action, items: items, pane: pane)
        }
    }

    private func actionPresentation(
        _ action: FileTableAction,
        _ items: [FileItem]
    ) -> FileCapabilityPresentationState? {
        let operation: FileSourceOperation
        switch action {
        case .open:
            operation = .open
        case .editTags:
            operation = .editTags
        case .rename:
            operation = .rename
        case .trash:
            operation = items.allSatisfy {
                if case .local = $0.location { true } else { false }
            } ? .trash : .delete
        case .revealInFinder:
            operation = .revealInFinder
        case .openInTerminal:
            operation = .openInTerminal
        case .quickLook:
            operation = .quickLook
        case .createFile:
            operation = .createFile
        case .createFolder:
            operation = .createFolder
        case .copyToOtherPane, .moveToOtherPane, .goBack, .goForward, .goUp,
             .refresh, .toggleHidden, .selectAll, .plugin:
            return nil
        }
        return pane.capabilityPresentationState(for: operation, items: items)
    }
}
