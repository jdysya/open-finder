import Foundation
import XCTest
import OpenFinderCore
@testable import OpenFinderApp

@MainActor
final class PluginWorkspaceTests: XCTestCase {
    func testProcessWorkspaceBehaviorRemainsUnchanged() {
        let localDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let taskID = UUID()

        let local = PluginWorkspace.make(taskID: taskID, currentLocation: .local(path: localDirectory.path))
        let remote = PluginWorkspace.make(
            taskID: taskID,
            currentLocation: .webDAV(accountID: UUID(), path: "/remote")
        )

        XCTAssertEqual(local.outputDirectory.standardizedFileURL, localDirectory.standardizedFileURL)
        XCTAssertTrue(local.tempDirectory.path.contains(taskID.uuidString))
        XCTAssertEqual(local.cleanupPolicy, .preserve)
        XCTAssertEqual(remote.outputDirectory.lastPathComponent, "output")
        XCTAssertEqual(remote.outputDirectory.deletingLastPathComponent(), remote.tempDirectory)
    }

    func testHTTPWorkspaceUsesSiblingTempAndOutputInsideTaskRoot() {
        let taskID = UUID()

        let workspace = PluginWorkspace.makeHTTP(taskID: taskID)

        XCTAssertEqual(workspace.tempDirectory.lastPathComponent, "temp")
        XCTAssertEqual(workspace.outputDirectory.lastPathComponent, "output")
        XCTAssertNotEqual(workspace.tempDirectory, workspace.outputDirectory)
        XCTAssertEqual(workspace.tempDirectory.deletingLastPathComponent(), workspace.taskRoot)
        XCTAssertEqual(workspace.outputDirectory.deletingLastPathComponent(), workspace.taskRoot)
        XCTAssertTrue(workspace.taskRoot.path.contains(taskID.uuidString))
        XCTAssertEqual(workspace.cleanupPolicy, .removeTaskRootAfterExecution)
    }
}
