import Foundation
import OpenFinderCore

extension AppModel {
    func dropLocalFileURLs(_ urls: [URL], into pane: BrowserPaneModel) {
        activePane = pane.id
        let destinationLocation = pane.location
        Task {
            do {
                let items = try await DroppedLocalFileItems.resolve(urls)
                guard !items.isEmpty else { return }
                let sourceLocation = items.first?.location
                    ?? .local(path: urls[0].deletingLastPathComponent().path)
                let title = "Copy dropped \(items.count) item(s)"
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
                        remoteProviderResolver: self.remoteProviderResolver,
                        progress: { fraction, message in
                            Task { await context.updateProgress(fraction, message) }
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

    func copySelectionToOtherPane(move: Bool) {
        let source = activeBrowser
        let destination = inactiveBrowser
        let selected = source.selectedItems
        let sourceLocation = source.location
        let destinationLocation = destination.location
        guard !selected.isEmpty else { return }
        let conflicts = TransferConflictDetector.conflicts(
            for: selected,
            destination: destinationLocation
        )
        if !conflicts.isEmpty {
            pendingTransferOverwrite = PendingTransferOverwrite(
                items: selected,
                source: sourceLocation,
                destination: destinationLocation,
                move: move,
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
            move: move,
            overwriteExisting: false,
            sourcePaneID: source.id,
            destinationPaneID: destination.id
        )
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
        Task {
            do {
                let title = move
                    ? "Move \(selected.count) item(s)"
                    : "Copy \(selected.count) item(s)"
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
                        remoteProviderResolver: self.remoteProviderResolver,
                        progress: { fraction, message in
                            Task { await context.updateProgress(fraction, message) }
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
}
