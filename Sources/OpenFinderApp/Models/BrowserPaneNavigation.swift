import AppKit
import Foundation
import OpenFinderCore

extension BrowserPaneModel {
    func refresh() async {
        await refresh(preservingTagEditorSession: nil)
    }

    func refresh(preservingTagEditorSession session: TagEditorSession?) async {
        let refreshedLocation = location
        let refreshedLocationGeneration = locationGeneration
        listingGeneration &+= 1
        let refreshedListingGeneration = listingGeneration
        isLoading = true
        errorMessage = nil
        hideListingParentWhileRefreshing()
        defer {
            if listingGeneration == refreshedListingGeneration {
                isLoading = false
            }
        }
        do {
            let listing = try await listItems(at: refreshedLocation)
            guard location == refreshedLocation,
                  locationGeneration == refreshedLocationGeneration,
                  listingGeneration == refreshedListingGeneration
            else {
                return
            }
            if let session, !isCurrentTagEditorSession(session) {
                return
            }
            publish(listing)
            if session != nil {
                isRestoringTagEditorSelection = true
                selection.formIntersection(Set(items.map(\.id)))
                isRestoringTagEditorSelection = false
            } else {
                selection.formIntersection(Set(items.map(\.id)))
            }
            refreshDirectorySizeCalculations(for: items)
        } catch {
            guard location == refreshedLocation,
                  locationGeneration == refreshedLocationGeneration,
                  listingGeneration == refreshedListingGeneration,
                  session.map(isCurrentTagEditorSession) ?? true
            else {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func navigate(to newLocation: Location, recordHistory: Bool = true) async {
        location = newLocation
        selection = []
        if recordHistory {
            if historyIndex + 1 < history.count {
                history.removeSubrange((historyIndex + 1)..<history.count)
            }
            history.append(newLocation)
            historyIndex = history.count - 1
        }
        await refresh()
    }

    func open(_ item: FileItem) {
        do {
            try requireCapability(.open, items: [item])
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if item.isDirectory {
            Task { await navigate(to: item.location) }
        } else if let url = item.localURL {
            NSWorkspace.shared.open(url)
        } else {
            Task {
                do {
                    NSWorkspace.shared.open(try await materializeRemoteFile(item))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        Task { await navigate(to: history[historyIndex], recordHistory: false) }
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        Task { await navigate(to: history[historyIndex], recordHistory: false) }
    }

    func goUp() {
        switch location {
        case .local:
            guard let url = location.localURL else { return }
            let parent = url.deletingLastPathComponent()
            Task { await navigate(to: .local(path: parent.path)) }
        case .webDAV, .remote:
            guard let remoteLocation = try? remoteLocation(for: location),
                  let remoteParent
            else {
                return
            }
            Task {
                await navigate(to: .remote(.init(
                    accountID: remoteLocation.accountID,
                    connectorID: remoteLocation.connectorID,
                    path: remoteParent
                )))
            }
        case .rclone:
            break
        }
    }

    func toggleHidden() {
        showHiddenFiles.toggle()
        Task { await refresh() }
    }
}
