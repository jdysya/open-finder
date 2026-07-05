import Foundation

public typealias TaskID = UUID

public protocol FileProvider {
    func list(_ location: Location, options: FileListOptions) async throws -> [FileItem]
    func stat(_ location: Location) async throws -> FileItem
    func createFolder(at location: Location, name: String) async throws
    func createFile(at location: Location, name: String) async throws
    func rename(_ item: FileItem, to newName: String) async throws -> FileItem
    func trashOrDelete(_ items: [FileItem]) async throws
    func copy(_ items: [FileItem], to destination: Location) async throws -> TaskID
    func move(_ items: [FileItem], to destination: Location) async throws -> TaskID
}

public enum FileSort: Hashable, Sendable {
    case name(ascending: Bool)
    case modificationDate(ascending: Bool)
    case size(ascending: Bool)
    case kind(ascending: Bool)
}

public struct FileListOptions: Hashable, Sendable {
    public var showHiddenFiles: Bool
    public var sort: FileSort

    public init(showHiddenFiles: Bool = false, sort: FileSort = .name(ascending: true)) {
        self.showHiddenFiles = showHiddenFiles
        self.sort = sort
    }
}

public enum FileBrowserFilter {
    public static func apply(_ items: [FileItem], text: String) -> [FileItem] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }
}
