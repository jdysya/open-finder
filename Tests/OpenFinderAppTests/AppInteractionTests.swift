import AppKit
import XCTest
import OpenFinderCore
@testable import OpenFinderApp

@MainActor
final class AppInteractionTests: XCTestCase {
    func testPluginWorkspaceUsesCurrentLocalDirectoryForOutputs() {
        let currentDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let taskID = UUID()

        let workspace = PluginWorkspace.make(taskID: taskID, currentLocation: .local(path: currentDirectory.path))

        XCTAssertEqual(workspace.outputDirectory.standardizedFileURL, currentDirectory.standardizedFileURL)
        XCTAssertTrue(workspace.tempDirectory.path.contains(taskID.uuidString))
    }

    func testPluginWorkspaceFallsBackToTemporaryOutputForRemoteLocations() {
        let taskID = UUID()
        let accountID = UUID()

        let workspace = PluginWorkspace.make(taskID: taskID, currentLocation: .webDAV(accountID: accountID, path: "/remote"))

        XCTAssertTrue(workspace.outputDirectory.path.contains(taskID.uuidString))
        XCTAssertTrue(workspace.outputDirectory.lastPathComponent == "output")
    }

    func testKeyboardShortcutsMapToFileTableActions() {
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "\r", keyCode: 36, modifiers: []), .open)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: " ", keyCode: 49, modifiers: []), .quickLook)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "\u{7F}", keyCode: 51, modifiers: []), .trash)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: nil, keyCode: 120, modifiers: []), .rename)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "[", keyCode: 33, modifiers: [.command]), .goBack)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "]", keyCode: 30, modifiers: [.command]), .goForward)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: nil, keyCode: 126, modifiers: [.command]), .goUp)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "r", keyCode: 15, modifiers: [.command]), .refresh)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: ".", keyCode: 47, modifiers: [.command, .shift]), .toggleHidden)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "n", keyCode: 45, modifiers: [.command]), .createFile)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "n", keyCode: 45, modifiers: [.command, .shift]), .createFolder)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "c", keyCode: 8, modifiers: [.command, .option]), .copyToOtherPane)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "v", keyCode: 9, modifiers: [.command, .option]), .moveToOtherPane)
    }

    func testDroppedLocalFileURLsBecomeLocalFileItems() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderDroppedFiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("drop.txt")
        try "drop".write(to: file, atomically: true, encoding: .utf8)

        let items = try await DroppedLocalFileItems.resolve([file])

        XCTAssertEqual(items.map(\.name), ["drop.txt"])
        XCTAssertEqual(items.first?.location, .local(path: file.path))
    }
}
