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
    let locationCapabilities: FileSourceCapabilities
    let listingCapabilities: FileListingCapabilities
    let providerRevision: String
    let items: [FileItem]
    let parentLocation: Location?

    func retainingItemsWithoutParent() -> Self {
        .init(
            locationCapabilities: locationCapabilities,
            listingCapabilities: listingCapabilities,
            providerRevision: providerRevision,
            items: items,
            parentLocation: nil
        )
    }
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
    @Published private(set) var fileSourceListing: BrowserPaneListing?
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
    let fileSourceRegistry: FileSourceRegistry
    let providerRevisionResolver: @Sendable (Location) async -> String
    var directorySizeCache: [String: Int64] = [:]
    var directorySizeTasks: [String: Task<Void, Never>] = [:]
    var materializationLeases: [MaterializationLease] = []
    var tagEditorSession: TagEditorSession?
    var tagEditorGeneration: UInt64 = 0
    var locationGeneration: UInt64 = 0
    var listingGeneration: UInt64 = 0
    var isRestoringTagEditorSelection = false

    init(
        id: PaneID,
        location: Location,
        remoteProviderResolver: @escaping @Sendable (RemoteLocation) async throws -> any RemoteProvider,
        fileSourceRegistry: FileSourceRegistry? = nil,
        providerRevisionResolver: @escaping @Sendable (Location) async -> String = {
            switch $0.fileLocation {
            case .resolved(let location):
                switch location.sourceID {
                case .local:
                    "local"
                case .remote(_, let connectorID):
                    connectorID.rawValue
                }
            case .unsupported:
                "unsupported"
            }
        }
    ) {
        self.id = id
        self.location = location
        history = [location]
        self.remoteProviderResolver = remoteProviderResolver
        self.providerRevisionResolver = providerRevisionResolver
        if let fileSourceRegistry {
            self.fileSourceRegistry = fileSourceRegistry
        } else {
            self.fileSourceRegistry = FileSourceRegistry(
                remoteProviderRegistry: RemoteProviderRegistry { accountID, revision in
                    guard let accountID = UUID(uuidString: accountID) else {
                        throw RemoteProviderRegistry.UnsupportedProviderError(
                            accountID: accountID,
                            revision: revision
                        )
                    }
                    return try await remoteProviderResolver(.init(
                        accountID: accountID,
                        connectorID: .init(rawValue: revision),
                        path: .init(identifier: "/", displayPath: "/")
                    ))
                }
            )
        }
    }

    deinit {
        for task in directorySizeTasks.values { task.cancel() }
        for lease in materializationLeases { try? lease.release() }
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

    var locationCapabilities: FileSourceCapabilities? {
        fileSourceListing?.locationCapabilities
    }

    var listingCapabilities: FileListingCapabilities? {
        fileSourceListing?.listingCapabilities
    }

    var listingProviderRevision: String? {
        fileSourceListing?.providerRevision
    }

    var remoteParent: RemotePath? {
        guard let parent = fileSourceListing?.parentLocation,
              case .resolved(let location) = parent.fileLocation
        else {
            return nil
        }
        return location.remoteLocation?.path
    }

    var parentLocation: Location? {
        fileSourceListing?.parentLocation
    }

    func hideListingParentWhileRefreshing() {
        fileSourceListing = fileSourceListing?.retainingItemsWithoutParent()
    }

    func publish(_ listing: BrowserPaneListing) {
        fileSourceListing = listing
        items = listing.items
    }
}
