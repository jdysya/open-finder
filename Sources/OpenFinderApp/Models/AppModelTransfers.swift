import Foundation
import OpenFinderCore

enum TransferAction {
    case copy
    case move

    var movesItems: Bool {
        switch self {
        case .copy:
            false
        case .move:
            true
        }
    }
}

extension AppModel {
    func dropLocalFileURLs(_ urls: [URL], into pane: BrowserPaneModel) {
        activePane = pane.id
        let destinationLocation = pane.location
        Task {
            do {
                let items = try await DroppedLocalFileItems.resolve(urls)
                guard !items.isEmpty else { return }
                let sourceLocation = Location.local(
                    path: urls[0].deletingLastPathComponent().path
                )
                let title = "Copy dropped \(items.count) item(s)"
                let transferID = UUID()
                let queuedID = try await taskQueue.enqueue(.init(
                    kind: .localCopy,
                    title: title
                ) { context in
                    await context.appendLog("\(title) to \(destinationLocation.displayPath)")
                    try await FileTransferService.copyOrMove(
                        items,
                        from: sourceLocation,
                        to: destinationLocation,
                        move: false,
                        taskID: transferID,
                        remoteProviderResolver: self.remoteProviderResolver,
                        progress: { fraction, message in
                            await context.updateProgress(fraction, message)
                        }
                    )
                    await context.updateProgress(1.0, "Finished")
                    return .success(summary: title, clipboard: nil)
                })
                await observeTask(queuedID)
                await pane.refresh()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func transferActionPresentationState(
        for action: TransferAction
    ) -> FileCapabilityPresentationState {
        activeBrowser.capabilityPresentationState(for: .open)
    }

    func performTransferAction(_ action: TransferAction) {
        let source = activeBrowser
        let destination = inactiveBrowser
        let selected = source.selectedItems
        let sourceLocation = source.location
        let destinationLocation = destination.location
        guard !selected.isEmpty else { return }
        guard preflightTransfer(
            selected,
            sourcePaneID: source.id
        ) else { return }
        let conflicts = TransferConflictDetector.conflicts(
            for: selected,
            destination: destinationLocation
        )
        if !conflicts.isEmpty {
            pendingTransferOverwrite = PendingTransferOverwrite(
                items: selected,
                source: sourceLocation,
                destination: destinationLocation,
                move: action.movesItems,
                conflicts: conflicts,
                sourcePaneID: source.id,
                destinationPaneID: destination.id
            )
            return
        }
        enqueueTransfer(
            selected,
            source: sourceLocation,
            destination: destinationLocation,
            move: action.movesItems,
            overwriteExisting: false,
            sourcePaneID: source.id,
            destinationPaneID: destination.id
        )
    }

    func copySelectionToOtherPane(move: Bool) {
        performTransferAction(move ? .move : .copy)
    }

    func confirmPendingTransferOverwrite(
        _ confirmedPending: PendingTransferOverwrite? = nil
    ) {
        guard let pending = confirmedPending ?? pendingTransferOverwrite else { return }
        pendingTransferOverwrite = nil
        enqueueTransfer(
            pending.items,
            source: pending.source,
            destination: pending.destination,
            move: pending.move,
            overwriteExisting: true,
            sourcePaneID: pending.sourcePaneID,
            destinationPaneID: pending.destinationPaneID
        )
    }

    func cancelPendingTransferOverwrite() {
        pendingTransferOverwrite = nil
    }

    private func enqueueTransfer(
        _ selected: [FileItem],
        source sourceLocation: Location,
        destination destinationLocation: Location,
        move: Bool,
        overwriteExisting: Bool,
        sourcePaneID: PaneID,
        destinationPaneID: PaneID
    ) {
        guard preflightTransfer(selected, sourcePaneID: sourcePaneID) else { return }
        Task {
            do {
                let title = move
                    ? "Move \(selected.count) item(s)"
                    : "Copy \(selected.count) item(s)"
                let transferID = UUID()
                let queuedID = try await taskQueue.enqueue(.init(
                    kind: move ? .localMove : .localCopy,
                    title: title
                ) { context in
                    await context.appendLog("\(title) to \(destinationLocation.displayPath)")
                    try await FileTransferService.copyOrMove(
                        selected,
                        from: sourceLocation,
                        to: destinationLocation,
                        move: move,
                        overwriteExisting: overwriteExisting,
                        taskID: transferID,
                        remoteProviderResolver: self.remoteProviderResolver,
                        progress: { fraction, message in
                            await context.updateProgress(fraction, message)
                        }
                    )
                    await context.updateProgress(1.0, "Finished")
                    return .success(summary: title, clipboard: nil)
                })
                await observeTask(queuedID)
                await browser(for: sourcePaneID).refresh()
                await browser(for: destinationPaneID).refresh()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func preflightTransfer(
        _ selected: [FileItem],
        sourcePaneID: PaneID
    ) -> Bool {
        do {
            try browser(for: sourcePaneID).requireCapability(.open, items: selected)
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }
}
