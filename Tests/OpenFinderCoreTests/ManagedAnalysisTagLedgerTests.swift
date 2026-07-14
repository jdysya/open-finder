import XCTest
@testable import OpenFinderCore

final class ManagedAnalysisTagLedgerTests: XCTestCase {
    func testReconcileDoesNotClaimPreexistingManualTag() {
        let current = [FileTag.local(name: "Manual")]
        let suggested = [Self.suggestion("Manual"), Self.suggestion("Analyzer")]

        let result = ManagedAnalysisTagLedger.reconcile(
            current: current,
            suggested: suggested,
            previouslyManaged: []
        )

        XCTAssertEqual(result.additions, ["Analyzer"])
        XCTAssertEqual(result.removals, [])
        XCTAssertEqual(result.nextManaged, ["Analyzer"])
    }

    func testReconcileRemovesOnlyStaleManagedTagsThatStillExist() {
        let current = [FileTag.local(name: "Keep"), FileTag.local(name: "Stale"), FileTag.local(name: "Manual")]

        let result = ManagedAnalysisTagLedger.reconcile(
            current: current,
            suggested: [Self.suggestion("Keep")],
            previouslyManaged: ["Keep", "Stale", "AlreadyRemoved"]
        )

        XCTAssertEqual(result.additions, [])
        XCTAssertEqual(result.removals, ["Stale"])
        XCTAssertEqual(result.nextManaged, ["Keep"])
    }

    func testReconcileIsIdempotentAfterApplyingChanges() {
        let first = ManagedAnalysisTagLedger.reconcile(
            current: [],
            suggested: [Self.suggestion("Analyzer")],
            previouslyManaged: []
        )
        let second = ManagedAnalysisTagLedger.reconcile(
            current: [FileTag.local(name: "Analyzer")],
            suggested: [Self.suggestion("Analyzer")],
            previouslyManaged: first.nextManaged
        )

        XCTAssertEqual(second.additions, [])
        XCTAssertEqual(second.removals, [])
        XCTAssertEqual(second.nextManaged, ["Analyzer"])
    }

    private static func suggestion(_ name: String) -> VideoAnalysisTagSuggestion {
        .init(name: name, category: "scene", confidence: 0.9, frameRatio: 0.5, source: "joytag", modelVersion: "1")
    }
}
