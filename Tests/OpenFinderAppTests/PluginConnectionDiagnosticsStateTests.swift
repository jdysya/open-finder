import OpenFinderCore
import XCTest
@testable import OpenFinderApp

final class PluginConnectionDiagnosticsStateTests: XCTestCase {
    func testButtonAndSubmissionAvailabilityFollowConnectionState() {
        let untested = PluginConnectionDiagnosticsState(status: nil)
        XCTAssertTrue(untested.isTestButtonEnabled)
        XCTAssertFalse(untested.isSubmissionEnabled)
        XCTAssertEqual(untested.title, "Not Tested")

        let connecting = PluginConnectionDiagnosticsState(status: .init(
            state: .connecting,
            guidance: "Checking"
        ))
        XCTAssertFalse(connecting.isTestButtonEnabled)
        XCTAssertFalse(connecting.isSubmissionEnabled)

        let ready = PluginConnectionDiagnosticsState(status: .init(
            state: .ready,
            guidance: "Ready"
        ))
        XCTAssertTrue(ready.isTestButtonEnabled)
        XCTAssertTrue(ready.isSubmissionEnabled)

        let degraded = PluginConnectionDiagnosticsState(status: .init(
            state: .degraded,
            issue: .environmentUnavailable,
            guidance: "Resolve checks"
        ))
        XCTAssertTrue(degraded.isTestButtonEnabled)
        XCTAssertFalse(degraded.isSubmissionEnabled)
    }
}
