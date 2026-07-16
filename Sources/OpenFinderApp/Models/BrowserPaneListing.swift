import Foundation
import OpenFinderCore

extension BrowserPaneModel {
    func listItems(at location: Location) async throws -> BrowserPaneListing {
        switch location {
        case .local:
            return .init(
                items: try await provider.list(
                    location,
                    options: .init(
                        showHiddenFiles: showHiddenFiles,
                        sort: .name(ascending: true)
                    )
                ),
                remoteParent: nil
            )
        case .webDAV, .remote:
            let remoteLocation = try remoteLocation(for: location)
            let remote = try await remoteProvider(for: remoteLocation)
            let listing = try await remote.list(directory: remoteLocation.path)
            let fileItems = listing.items.map { remoteItem in
                FileItem(
                    id: "remote:\(remoteLocation.accountID.uuidString):\(remoteItem.remotePath.identifier)",
                    name: remoteItem.name,
                    location: .remote(.init(
                        accountID: remoteLocation.accountID,
                        connectorID: remoteLocation.connectorID,
                        path: remoteItem.remotePath
                    )),
                    kind: remoteItem.kind,
                    size: remoteItem.size,
                    modificationDate: remoteItem.modificationDate,
                    creationDate: nil,
                    uti: nil,
                    mimeType: remoteItem.mimeType,
                    fileExtension: URL(fileURLWithPath: remoteItem.name).pathExtension.isEmpty
                        ? nil
                        : URL(fileURLWithPath: remoteItem.name).pathExtension.lowercased(),
                    isHidden: remoteItem.name.hasPrefix("."),
                    isReadable: remoteItem.isReadable,
                    isWritable: remoteItem.isWritable,
                    tags: remoteItem.tags,
                    tagScopes: remoteItem.tagScopes,
                    supportsTagEditing: remoteItem.supportsTagEditing
                )
            }
            return .init(items: sortItems(fileItems), remoteParent: listing.parent)
        case .rclone:
            throw OpenFinderError.unsupportedLocation(location)
        }
    }

    func refreshDirectorySizeCalculations(for listedItems: [FileItem]) {
        let currentIDs = Set(listedItems.map(\.id))
        directorySizeText = directorySizeText.filter { currentIDs.contains($0.key) }
        let obsoleteTaskIDs = directorySizeTasks.keys.filter { !currentIDs.contains($0) }
        for id in obsoleteTaskIDs {
            directorySizeTasks.removeValue(forKey: id)?.cancel()
        }

        for item in listedItems where item.isDirectory && item.localURL != nil {
            if let cached = directorySizeCache[item.id] {
                directorySizeText[item.id] = FileSizeFormatter.openFinderString(
                    fromByteCount: cached
                )
                continue
            }
            if directorySizeTasks[item.id] != nil { continue }
            directorySizeText[item.id] = "计算中…"
            let id = item.id
            let location = item.location
            let provider = LocalFileProvider()
            directorySizeTasks[id] = Task { [weak self] in
                do {
                    let size = try await provider.directorySize(at: location)
                    self?.completeDirectorySize(id: id, size: size)
                } catch {
                    self?.completeDirectorySize(id: id, size: nil)
                }
            }
        }
    }

    private func completeDirectorySize(id: String, size: Int64?) {
        directorySizeTasks.removeValue(forKey: id)
        guard items.contains(where: { $0.id == id }) else { return }
        if let size {
            directorySizeCache[id] = size
            directorySizeText[id] = FileSizeFormatter.openFinderString(fromByteCount: size)
        } else {
            directorySizeText[id] = "—"
        }
    }

    private func sortItems(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func uniqueName(base: String) -> String {
        guard let root = location.localURL else { return base }
        let ext = URL(fileURLWithPath: base).pathExtension
        let stem = ext.isEmpty ? base : String(base.dropLast(ext.count + 1))
        var candidate = base
        var index = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            index += 1
        }
        return candidate
    }
}
