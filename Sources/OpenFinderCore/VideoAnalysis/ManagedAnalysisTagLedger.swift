import Foundation

public struct ManagedAnalysisTagReconciliation: Equatable, Sendable {
    public let additions: [String]
    public let removals: [String]
    public let nextManaged: [String]

    public init(additions: [String], removals: [String], nextManaged: [String]) {
        self.additions = additions
        self.removals = removals
        self.nextManaged = nextManaged
    }
}

public enum ManagedAnalysisTagLedger {
    public static func reconcile(
        current: [FileTag],
        suggested: [VideoAnalysisTagSuggestion],
        previouslyManaged: [String]
    ) -> ManagedAnalysisTagReconciliation {
        let currentNames = Set(current.map(\.name))
        let suggestedNames = Set(suggested.map(\.name).filter { !$0.isEmpty })
        let previousNames = Set(previouslyManaged)
        let additions = suggestedNames.subtracting(currentNames)
        let removals = previousNames.subtracting(suggestedNames).intersection(currentNames)
        let retained = previousNames.intersection(suggestedNames)
        return .init(
            additions: additions.sorted(),
            removals: removals.sorted(),
            nextManaged: retained.union(additions).sorted()
        )
    }
}
