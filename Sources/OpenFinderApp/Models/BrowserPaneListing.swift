import Foundation
import OpenFinderCore

extension BrowserPaneModel {
    func listItems(at location: Location) async throws -> BrowserPaneListing {
        let revision = await providerRevisionResolver(location)
        return try await fileBrowserService.listing(
            at: location,
            showHiddenFiles: showHiddenFiles,
            revision: revision
        )
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

}
