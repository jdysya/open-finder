import Foundation

public struct PaneState: Identifiable, Codable, Sendable {
    public var id: UUID
    public var location: Location
    public var items: [FileItem]
    public var selection: Set<FileItem.ID>
    public var sortDescription: String
    public var filterText: String
    public var showHiddenFiles: Bool
    public var history: [Location]
    public var historyIndex: Int
    public var isLoading: Bool
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        location: Location,
        items: [FileItem] = [],
        selection: Set<FileItem.ID> = [],
        sortDescription: String = "nameAscending",
        filterText: String = "",
        showHiddenFiles: Bool = false,
        history: [Location] = [],
        historyIndex: Int = -1,
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.location = location
        self.items = items
        self.selection = selection
        self.sortDescription = sortDescription
        self.filterText = filterText
        self.showHiddenFiles = showHiddenFiles
        self.history = history
        self.historyIndex = historyIndex
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }
}
