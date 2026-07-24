import Foundation
import OpenFinderCore
import SwiftUI

struct TagEditorSession {
    let generation: UInt64
    let location: Location
    let context: TagEditorContext
    let provider: any TagProvider
}

struct BrowserPaneListing {
    let items: [FileItem]
    let remoteParent: RemotePath?
}

@MainActor
final class BrowserPaneModel: ObservableObject, Identifiable {
    let id: PaneID
    @Published var location: Location {
        didSet {
            guard location != oldValue else { return }
            locationGeneration &+= 1
            invalidateTagEditorSession()
        }
    }
    @Published var items: [FileItem] = []
    @Published var selection: Set<String> = [] {
        didSet {
            guard selection != oldValue, !isRestoringTagEditorSelection else { return }
            invalidateTagEditorSession()
        }
    }
    @Published var filterText: String = ""
    @Published var showHiddenFiles: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var pendingDeletion: PendingDeletion?
    @Published var directorySizeText: [String: String] = [:]
    @Published var history: [Location]
    @Published var historyIndex: Int = 0

    let provider = LocalFileProvider()
    let remoteProviderResolver: @Sendable (RemoteLocation) async throws -> any RemoteProvider
    var directorySizeCache: [String: Int64] = [:]
    var directorySizeTasks: [String: Task<Void, Never>] = [:]
    var remoteParent: RemotePath?
    let remoteMaterializationDirectory: URL
    var tagEditorSession: TagEditorSession?
    var tagEditorGeneration: UInt64 = 0
    var locationGeneration: UInt64 = 0
    var isRestoringTagEditorSelection = false

    init(
        id: PaneID,
        location: Location,
        remoteProviderResolver: @escaping @Sendable (RemoteLocation) async throws -> any RemoteProvider
    ) {
        self.id = id
        self.location = location
        history = [location]
        self.remoteProviderResolver = remoteProviderResolver
        remoteMaterializationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderRemoteFiles-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        for task in directorySizeTasks.values { task.cancel() }
        try? FileManager.default.removeItem(at: remoteMaterializationDirectory)
    }

    var visibleItems: [FileItem] {
        FileBrowserFilter.apply(items, text: filterText)
    }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.id) }
    }

    func openFirstSelected() {
        guard let item = selectedItems.first else { return }
        open(item)
    }

    func selectAllVisible() {
        selection = Set(visibleItems.map(\.id))
    }

    var hasRemoteSelection: Bool {
        selectedItems.contains { item in
            if case .local = item.location { return false }
            return true
        }
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
}
