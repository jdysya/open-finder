import AppKit
import Foundation
import OpenFinderCore

extension BrowserPaneModel {
    func createFolder() {
        Task {
            do {
                switch location {
                case .local:
                    try await provider.createFolder(
                        at: location,
                        name: uniqueName(base: "New Folder")
                    )
                case .webDAV, .remote:
                    let remoteLocation = try remoteLocation(for: location)
                    let remote = try await remoteProvider(for: remoteLocation)
                    try await remote.createDirectory(in: remoteLocation.path, named: "New Folder")
                case .rclone:
                    throw OpenFinderError.unsupportedLocation(location)
                }
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func createFile() {
        Task {
            do {
                switch location {
                case .local:
                    try await provider.createFile(
                        at: location,
                        name: uniqueName(base: "Untitled.txt")
                    )
                case .webDAV, .remote:
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("OpenFinder-empty-\(UUID().uuidString).txt")
                    FileManager.default.createFile(atPath: temp.path, contents: Data())
                    defer { try? FileManager.default.removeItem(at: temp) }
                    let remoteLocation = try remoteLocation(for: location)
                    let remote = try await remoteProvider(for: remoteLocation)
                    _ = try await remote.upload(
                        localURL: temp,
                        to: remoteLocation.path,
                        named: "Untitled.txt"
                    )
                case .rclone:
                    throw OpenFinderError.unsupportedLocation(location)
                }
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func renameFirstSelected(to newName: String) {
        guard let item = selectedItems.first else { return }
        Task {
            do {
                switch item.location {
                case .local:
                    _ = try await provider.rename(item, to: newName)
                case .webDAV, .remote:
                    let itemLocation = try remoteLocation(for: item.location)
                    let destinationLocation = try remoteLocation(for: location)
                    let remote = try await remoteProvider(for: itemLocation)
                    try await remote.move(
                        item: itemLocation.path,
                        to: destinationLocation.path,
                        named: newName
                    )
                case .rclone:
                    throw OpenFinderError.unsupportedLocation(item.location)
                }
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func trashSelected() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        if selected.contains(where: { item in
            if case .local = item.location { return false }
            return true
        }) {
            pendingDeletion = PendingDeletion(items: selected)
            return
        }
        delete(selected)
    }

    func confirmPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        delete(pending.items)
    }

    func cancelPendingDeletion() {
        pendingDeletion = nil
    }

    private func delete(_ selected: [FileItem]) {
        Task {
            do {
                for item in selected {
                    switch item.location {
                    case .local:
                        try await provider.trashOrDelete([item])
                    case .webDAV, .remote:
                        let remoteLocation = try remoteLocation(for: item.location)
                        let remote = try await remoteProvider(for: remoteLocation)
                        try await remote.delete(item: remoteLocation.path)
                    case .rclone:
                        throw OpenFinderError.unsupportedLocation(item.location)
                    }
                }
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func revealSelectedInFinder() {
        let urls = selectedItems.compactMap(\.localURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openSelectedInTerminal() {
        let url = selectedItems.first?.localURL ?? location.localURL
        guard let url else { return }
        TerminalService.openTerminal(
            at: url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        )
    }

    func quickLookSelected() {
        let items = selectedItems
        Task {
            do {
                var urls = items.compactMap(\.localURL)
                for item in items where item.localURL == nil && !item.isDirectory {
                    urls.append(try await materializeRemoteFile(item))
                }
                QuickLookBridge.preview(urls: urls)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
