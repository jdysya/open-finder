import AppKit
import Foundation
import OpenFinderCore

struct PluginWorkspace: Equatable {
    let tempDirectory: URL
    let outputDirectory: URL

    static func make(taskID: UUID, currentLocation: Location) -> PluginWorkspace {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderTasks", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
        let outputDirectory: URL
        if let localURL = currentLocation.localURL {
            outputDirectory = localURL
        } else {
            outputDirectory = tempDirectory.appendingPathComponent("output", isDirectory: true)
        }
        return PluginWorkspace(tempDirectory: tempDirectory, outputDirectory: outputDirectory)
    }
}

enum FileTableKeyboardCommand: Equatable {
    case open
    case rename
    case trash
    case quickLook
    case goBack
    case goForward
    case goUp
    case refresh
    case toggleHidden
    case createFile
    case createFolder
    case copyToOtherPane
    case moveToOtherPane
    case selectAll
}

enum FileTableKeyboardShortcut {
    static func action(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> FileTableKeyboardCommand? {
        let flags = modifiers.intersection([.command, .option, .shift, .control])
        if flags.isEmpty {
            if characters == "\r" || keyCode == 36 { return .rename }
            if characters == " " || keyCode == 49 { return .quickLook }
            if characters == "\u{7F}" || keyCode == 51 || keyCode == 117 { return .trash }
            if keyCode == 120 { return .rename }
            return nil
        }
        if flags == [.command] {
            if characters == "[" { return .goBack }
            if characters == "]" { return .goForward }
            if keyCode == 126 { return .goUp }
            if keyCode == 125 { return .open }
            if keyCode == 51 || keyCode == 117 || characters == "\u{7F}" { return .trash }
            if characters?.lowercased() == "o" { return .open }
            if characters?.lowercased() == "a" { return .selectAll }
            if characters?.lowercased() == "r" { return .refresh }
            if characters?.lowercased() == "n" { return .createFile }
        }
        if flags == [.command, .shift] {
            if characters == "." { return .toggleHidden }
            if characters?.lowercased() == "n" { return .createFolder }
        }
        if flags == [.command, .option] {
            if characters?.lowercased() == "c" { return .copyToOtherPane }
            if characters?.lowercased() == "v" { return .moveToOtherPane }
        }
        return nil
    }
}

enum FileTablePointerSelection {
    static func shouldClearSelection(clickedRow: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        clickedRow < 0 && modifiers.intersection([.command, .option, .shift, .control]).isEmpty
    }
}

enum FileTableTagActionAvailability {
    static func commonEditableScope(for items: [FileItem]) -> FileTagScope? {
        guard let first = items.first,
              first.isWritable,
              first.supportsTagEditing
        else {
            return nil
        }

        return first.tagScopes.first { candidate in
            candidate.capabilities.canAssociate && items.allSatisfy { item in
                item.isWritable
                    && item.supportsTagEditing
                    && item.tagScopes.contains { scope in
                        scope.id == candidate.id && scope.capabilities.canAssociate
                    }
            }
        }
    }
}

struct FileTableSelectionResult: Equatable {
    let selectedRows: IndexSet
    let anchorRow: Int?
}

enum FileTableSelectionReducer {
    static func selection(
        selectedRows: IndexSet,
        anchorRow: Int?,
        clickedRow: Int,
        rowCount: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> FileTableSelectionResult {
        guard clickedRow >= 0, clickedRow < rowCount else {
            return FileTableSelectionResult(selectedRows: selectedRows, anchorRow: anchorRow)
        }

        let flags = modifiers.intersection([.command, .shift])
        if flags.contains(.shift) {
            let anchor = anchorRow ?? selectedRows.first ?? clickedRow
            let range = IndexSet(integersIn: min(anchor, clickedRow)...max(anchor, clickedRow))
            if flags.contains(.command) {
                var next = selectedRows
                next.formUnion(range)
                return FileTableSelectionResult(selectedRows: next, anchorRow: anchor)
            }
            return FileTableSelectionResult(selectedRows: range, anchorRow: anchor)
        }

        if flags.contains(.command) {
            var next = selectedRows
            if next.contains(clickedRow) {
                next.remove(clickedRow)
            } else {
                next.insert(clickedRow)
            }
            let nextAnchor = next.contains(clickedRow) ? clickedRow : next.last
            return FileTableSelectionResult(selectedRows: next, anchorRow: nextAnchor)
        }

        return FileTableSelectionResult(selectedRows: IndexSet(integer: clickedRow), anchorRow: clickedRow)
    }
}

struct TransferConflict: Equatable, Identifiable {
    var id: String { destinationPath }
    let itemName: String
    let destinationPath: String
}

enum TransferConflictDetector {
    static func conflicts(for items: [FileItem], destination: Location) -> [TransferConflict] {
        guard let destinationURL = destination.localURL else { return [] }
        return items.compactMap { item in
            let target = destinationURL.appendingPathComponent(item.name, isDirectory: item.isDirectory)
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            return TransferConflict(itemName: item.name, destinationPath: target.path)
        }
    }
}

enum LocalPathCompletion {
    static func resolvedPath(_ input: String, relativeTo baseURL: URL) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPath: String
        if trimmed.hasPrefix("~") {
            rawPath = NSString(string: trimmed).expandingTildeInPath
        } else if trimmed.hasPrefix("/") {
            rawPath = trimmed
        } else {
            rawPath = baseURL.appendingPathComponent(trimmed).path
        }
        return URL(fileURLWithPath: rawPath).standardizedFileURL.path
    }

    static func suggestions(for input: String, relativeTo baseURL: URL, limit: Int = 6) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let resolved = resolvedPath(trimmed, relativeTo: baseURL)
        let inputEndsWithSeparator = trimmed.hasSuffix("/")
        let typedURL = URL(fileURLWithPath: resolved)
        let directoryURL = inputEndsWithSeparator ? typedURL : typedURL.deletingLastPathComponent()
        let prefix = inputEndsWithSeparator ? "" : typedURL.lastPathComponent.lowercased()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        return children.compactMap { url -> String? in
            guard prefix.isEmpty || url.lastPathComponent.lowercased().hasPrefix(prefix) else { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            guard values.isDirectory == true || values.isPackage == true else { return nil }
            return url.standardizedFileURL.path
        }
        .sorted()
        .prefix(limit)
        .map(\.self)
    }
}

enum DroppedLocalFileItems {
    static func resolve(_ urls: [URL]) async throws -> [FileItem] {
        let provider = LocalFileProvider()
        var items: [FileItem] = []
        for url in urls {
            items.append(try await provider.stat(.local(path: url.path)))
        }
        return items
    }
}
