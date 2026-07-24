import AppKit
import Foundation
import OpenFinderCore

struct BrowserPaneFileOperationAdapter {
    let location: FileLocationResolution
    let listingCapabilities: FileListingCapabilities?

    func decision(
        for operation: FileSourceOperation,
        items: [FileItem]
    ) -> FileCapabilityDecision {
        guard case .resolved(let fileLocation) = location else {
            guard case .unsupported(let reason) = location else {
                preconditionFailure("FileLocationResolution has an unknown case")
            }
            return .rejected(reason)
        }
        switch operation {
        case .createFile, .createFolder:
            return decision(listingSupport(.create, sourceID: fileLocation.sourceID))
        case .rename:
            guard items.count == 1 else {
                return .rejected(.singleSelectionRequired(operation: operation))
            }
            return combinedDecision(
                listingSupport(.create, sourceID: fileLocation.sourceID),
                itemSupport(.move, items: items, sourceID: fileLocation.sourceID)
            )
        case .delete:
            guard fileLocation.sourceID.isRemote else {
                return .rejected(.operationUnavailable(
                    sourceID: fileLocation.sourceID,
                    operation: operation
                ))
            }
            return decision(itemSupport(.delete, items: items, sourceID: fileLocation.sourceID))
        case .trash:
            guard !fileLocation.sourceID.isRemote else {
                return .rejected(.operationUnavailable(
                    sourceID: fileLocation.sourceID,
                    operation: operation
                ))
            }
            return decision(itemSupport(.delete, items: items, sourceID: fileLocation.sourceID))
        case .editTags:
            let support = combinedSupport(
                listingSupport(.tags, sourceID: fileLocation.sourceID),
                itemSupport(.tags, items: items, sourceID: fileLocation.sourceID)
            )
            guard support.isSupported else { return decision(support) }
            guard FileTableTagActionAvailability.commonEditableScope(for: items) != nil else {
                return .rejected(.tagScopeUnavailable)
            }
            return .allowed
        case .revealInFinder, .openInTerminal:
            guard !fileLocation.sourceID.isRemote else {
                return .rejected(.operationUnavailable(
                    sourceID: fileLocation.sourceID,
                    operation: operation
                ))
            }
            if operation == .revealInFinder, items.isEmpty {
                return .rejected(.selectionRequired(operation: operation))
            }
            return .allowed
        case .quickLook:
            guard !items.isEmpty else {
                return .rejected(.selectionRequired(operation: operation))
            }
            if fileLocation.sourceID.isRemote, items.contains(where: \.isDirectory) {
                return .rejected(.operationUnavailable(
                    sourceID: fileLocation.sourceID,
                    operation: operation
                ))
            }
            return decision(itemSupport(.materialize, items: items, sourceID: fileLocation.sourceID))
        case .open:
            guard !items.isEmpty else {
                return .rejected(.selectionRequired(operation: operation))
            }
            let files = items.filter { !$0.isDirectory }
            if files.isEmpty {
                return decision(listingSupport(.list, sourceID: fileLocation.sourceID))
            }
            return decision(itemSupport(.materialize, items: files, sourceID: fileLocation.sourceID))
        }
    }

    func presentationState(
        for operation: FileSourceOperation,
        items: [FileItem]
    ) -> FileCapabilityPresentationState {
        FileCapabilityPresentationState(decision(for: operation, items: items))
    }

    func require(_ operation: FileSourceOperation, items: [FileItem]) throws {
        switch FileOperationPreflight.evaluate(decision(for: operation, items: items)) {
        case .proceed:
            return
        case .rejected(let reason):
            throw reason
        }
    }

    private func itemSupport(
        _ capability: FileCapability,
        items: [FileItem],
        sourceID: FileSourceID
    ) -> FileCapabilitySupport {
        guard !items.isEmpty else {
            return .unsupported(.selectionRequired(operation: operation(for: capability)))
        }
        for item in items {
            guard case .resolved(let itemLocation) = item.location.fileLocation,
                  itemLocation.sourceID == sourceID
            else {
                return .unsupported(.operationUnavailable(
                    sourceID: sourceID,
                    operation: operation(for: capability)
                ))
            }
            let support = FileItemCapabilities(sourceID: sourceID, metadata: item)[capability]
            if !support.isSupported { return support }
        }
        return .supported
    }

    private func listingSupport(
        _ capability: FileCapability,
        sourceID: FileSourceID
    ) -> FileCapabilitySupport {
        guard let listingCapabilities,
              listingCapabilities.source.sourceID == sourceID
        else {
            return .unsupported(.listingMetadataDenied)
        }
        return listingCapabilities[capability]
    }

    private func combinedDecision(
        _ first: FileCapabilitySupport,
        _ second: FileCapabilitySupport
    ) -> FileCapabilityDecision {
        decision(combinedSupport(first, second))
    }

    private func combinedSupport(
        _ first: FileCapabilitySupport,
        _ second: FileCapabilitySupport
    ) -> FileCapabilitySupport {
        first.isSupported ? second : first
    }

    private func decision(_ support: FileCapabilitySupport) -> FileCapabilityDecision {
        FileCapabilityDecision(support)
    }

    private func operation(for capability: FileCapability) -> FileSourceOperation {
        switch capability {
        case .create: .createFile
        case .delete: .delete
        case .move: .rename
        case .tags: .editTags
        case .list, .read, .copy, .materialize, .atomicPublish: .open
        }
    }
}

extension BrowserPaneModel {
    var fileOperationAdapter: BrowserPaneFileOperationAdapter {
        BrowserPaneFileOperationAdapter(
            location: location.fileLocation,
            listingCapabilities: listingCapabilities
        )
    }

    func capabilityDecision(
        for operation: FileSourceOperation,
        items: [FileItem]? = nil
    ) -> FileCapabilityDecision {
        fileOperationAdapter.decision(for: operation, items: items ?? selectedItems)
    }

    func capabilityPresentationState(
        for operation: FileSourceOperation,
        items: [FileItem]? = nil
    ) -> FileCapabilityPresentationState {
        fileOperationAdapter.presentationState(for: operation, items: items ?? selectedItems)
    }

    func requireCapability(
        _ operation: FileSourceOperation,
        items: [FileItem]? = nil
    ) throws {
        try fileOperationAdapter.require(operation, items: items ?? selectedItems)
    }

    func resolvedFileSource(for requestedLocation: Location) async throws -> ResolvedFileSource {
        let revision: String
        if case .resolved(let requested) = requestedLocation.fileLocation,
           requested.sourceID == locationCapabilities?.sourceID,
           let listingProviderRevision {
            revision = listingProviderRevision
        } else {
            revision = await providerRevisionResolver(requestedLocation)
        }
        return try await fileSourceRegistry.resolve(requestedLocation, revision: revision)
    }

    func createFolder() {
        Task {
            do {
                try requireCapability(.createFolder, items: [])
                let source = try await resolvedFileSource(for: location)
                try await source.createFolder(named: source.availableName("New Folder"))
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func createFile() {
        Task {
            do {
                try requireCapability(.createFile, items: [])
                let source = try await resolvedFileSource(for: location)
                try await source.createFile(named: source.availableName("Untitled.txt"))
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
                try requireCapability(.rename, items: [item])
                let itemSource = try await resolvedFileSource(for: item.location)
                let destinationSource = try await resolvedFileSource(for: location)
                guard itemSource.location.sourceID == destinationSource.location.sourceID else {
                    throw FileCapabilityUnsupportedReason.crossSource
                }
                try await itemSource.rename(item, to: newName, in: destinationSource)
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
            guard case .resolved(let location) = item.location.fileLocation else {
                return true
            }
            return location.sourceID.isRemote
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
                let operation: FileSourceOperation = selected.allSatisfy {
                    guard case .resolved(let location) = $0.location.fileLocation else {
                        return false
                    }
                    return !location.sourceID.isRemote
                } ? .trash : .delete
                try requireCapability(operation, items: selected)
                for item in selected {
                    let source = try await resolvedFileSource(for: item.location)
                    try await source.delete(item)
                }
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func revealSelectedInFinder() {
        do {
            try requireCapability(.revealInFinder)
            NSWorkspace.shared.activateFileViewerSelecting(selectedItems.compactMap(\.localURL))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openSelectedInTerminal() {
        do {
            try requireCapability(.openInTerminal)
            guard let url = selectedItems.first?.localURL ?? location.localURL else { return }
            TerminalService.openTerminal(
                at: url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func quickLookSelected() {
        let items = selectedItems
        Task {
            do {
                try requireCapability(.quickLook, items: items)
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
