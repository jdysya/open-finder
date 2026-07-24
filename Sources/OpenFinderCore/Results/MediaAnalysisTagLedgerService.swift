import Foundation

public struct MediaAnalysisTagLedgerUpdate: Hashable, Sendable {
    public let changes: FileTagChangeSet
    public let nextManagedTagNames: Set<String>

    public init(changes: FileTagChangeSet, nextManagedTagNames: Set<String>) {
        self.changes = changes
        self.nextManagedTagNames = nextManagedTagNames
    }
}

public struct MediaAnalysisTagLedgerService: Sendable {
    public init() {}

    public func update(
        document: MediaAnalysisDocument,
        item: MediaAnalysisItem,
        currentTags: [FileTag],
        selectedNames: Set<String>
    ) -> MediaAnalysisTagLedgerUpdate {
        update(
            ledger: document.managedTagLedger,
            item: item,
            currentTags: currentTags,
            selectedNames: selectedNames
        )
    }

    public func update(
        ledger: ManagedTagLedger,
        item: MediaAnalysisItem,
        currentTags: [FileTag],
        selectedNames: Set<String>
    ) -> MediaAnalysisTagLedgerUpdate {
        let currentNames = Set(currentTags.map(\.name))
        let availableNames = Set(item.suggestedTags.map(\.name))
        let selectedNames = selectedNames.intersection(availableNames)
        let reconciliation = ledger.reconcile(
            stableMediaID: item.media.stableID,
            currentTagNames: currentNames,
            suggestedTagNames: selectedNames
        )
        return .init(
            changes: .init(
                add: reconciliation.add.map(FileTag.local(name:)),
                remove: reconciliation.remove
                    .intersection(currentNames)
                    .map(FileTag.local(name:))
            ),
            nextManagedTagNames: reconciliation.nextManaged
        )
    }
}
