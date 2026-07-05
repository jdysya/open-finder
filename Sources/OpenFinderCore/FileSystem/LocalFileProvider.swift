import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public struct LocalFileProvider: FileProvider, @unchecked Sendable {
    private let trashItemHandler: @Sendable (URL) throws -> Void

    public init(trashItem: (@Sendable (URL) throws -> Void)? = nil) {
        self.trashItemHandler = trashItem ?? { url in
            #if os(macOS)
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            #else
            throw OpenFinderError.operationFailed("Move to Trash is not available on this platform")
            #endif
        }
    }

    public func list(_ location: Location, options: FileListOptions = .init()) async throws -> [FileItem] {
        let directory = try localURL(for: location)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .isReadableKey,
            .isWritableKey,
            .typeIdentifierKey,
            .contentTypeKey
        ]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [])
        let mapped = try urls.compactMap { url -> FileItem? in
            let item = try makeItem(url)
            if !options.showHiddenFiles && item.isHidden { return nil }
            return item
        }
        return sort(mapped, by: options.sort)
    }

    public func stat(_ location: Location) async throws -> FileItem {
        try makeItem(try localURL(for: location))
    }

    public func createFolder(at location: Location, name: String) async throws {
        let destination = try childURL(parent: localURL(for: location), name: name)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    }

    public func createFile(at location: Location, name: String) async throws {
        let destination = try childURL(parent: localURL(for: location), name: name)
        guard FileManager.default.createFile(atPath: destination.path, contents: Data()) else {
            throw OpenFinderError.operationFailed("Could not create file at \(destination.path)")
        }
    }

    public func rename(_ item: FileItem, to newName: String) async throws -> FileItem {
        let source = try localURL(for: item.location)
        let destination = try childURL(parent: source.deletingLastPathComponent(), name: newName)
        try FileManager.default.moveItem(at: source, to: destination)
        return try makeItem(destination)
    }

    public func trashOrDelete(_ items: [FileItem]) async throws {
        for item in items {
            let url = try localURL(for: item.location)
            try trashItemHandler(url)
        }
    }

    public func copy(_ items: [FileItem], to destination: Location) async throws -> TaskID {
        let destinationURL = try localURL(for: destination)
        for item in items {
            let source = try localURL(for: item.location)
            let target = destinationURL.appendingPathComponent(source.lastPathComponent, isDirectory: item.isDirectory)
            if FileManager.default.fileExists(atPath: target.path) {
                throw OpenFinderError.operationFailed("Destination already exists: \(target.path)")
            }
            try FileManager.default.copyItem(at: source, to: target)
        }
        return UUID()
    }

    public func move(_ items: [FileItem], to destination: Location) async throws -> TaskID {
        let destinationURL = try localURL(for: destination)
        for item in items {
            let source = try localURL(for: item.location)
            let target = destinationURL.appendingPathComponent(source.lastPathComponent, isDirectory: item.isDirectory)
            if FileManager.default.fileExists(atPath: target.path) {
                throw OpenFinderError.operationFailed("Destination already exists: \(target.path)")
            }
            try FileManager.default.moveItem(at: source, to: target)
        }
        return UUID()
    }

    private func localURL(for location: Location) throws -> URL {
        guard let url = location.localURL else { throw OpenFinderError.unsupportedLocation(location) }
        return url
    }

    private func childURL(parent: URL, name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/") else { throw OpenFinderError.invalidFileName(name) }
        return parent.appendingPathComponent(name)
    }

    private func makeItem(_ url: URL) throws -> FileItem {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .isReadableKey,
            .isWritableKey,
            .typeIdentifierKey,
            .contentTypeKey
        ])
        let kind: FileKind
        if values.isSymbolicLink == true {
            kind = .symlink
        } else if values.isPackage == true {
            kind = .package
        } else if values.isDirectory == true {
            kind = .directory
        } else {
            kind = .file
        }
        let ext = url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased()
        let mimeType: String?
        #if canImport(UniformTypeIdentifiers)
        if #available(macOS 11.0, *), let contentType = values.contentType {
            mimeType = contentType.preferredMIMEType
        } else {
            mimeType = nil
        }
        #else
        mimeType = nil
        #endif
        return FileItem(
            id: "local:\(url.standardizedFileURL.path)",
            name: url.lastPathComponent,
            location: .local(path: url.path),
            kind: kind,
            size: values.fileSize.map(Int64.init),
            modificationDate: values.contentModificationDate,
            creationDate: values.creationDate,
            uti: values.typeIdentifier,
            mimeType: mimeType,
            fileExtension: ext,
            isHidden: values.isHidden == true || url.lastPathComponent.hasPrefix("."),
            isReadable: values.isReadable ?? FileManager.default.isReadableFile(atPath: url.path),
            isWritable: values.isWritable ?? FileManager.default.isWritableFile(atPath: url.path)
        )
    }

    private func sort(_ items: [FileItem], by sort: FileSort) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            switch sort {
            case .name(let ascending):
                let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            case .modificationDate(let ascending):
                let l = lhs.modificationDate ?? .distantPast
                let r = rhs.modificationDate ?? .distantPast
                return ascending ? l < r : l > r
            case .size(let ascending):
                let l = lhs.size ?? -1
                let r = rhs.size ?? -1
                return ascending ? l < r : l > r
            case .kind(let ascending):
                let l = lhs.kind.rawValue
                let r = rhs.kind.rawValue
                return ascending ? l < r : l > r
            }
        }
    }
}
