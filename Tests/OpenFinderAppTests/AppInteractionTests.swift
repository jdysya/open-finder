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
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "\r", keyCode: 36, modifiers: []), .rename)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: " ", keyCode: 49, modifiers: []), .quickLook)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "\u{7F}", keyCode: 51, modifiers: []), .trash)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "\u{7F}", keyCode: 51, modifiers: [.command]), .trash)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: nil, keyCode: 120, modifiers: []), .rename)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "o", keyCode: 31, modifiers: [.command]), .open)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: nil, keyCode: 125, modifiers: [.command]), .open)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "[", keyCode: 33, modifiers: [.command]), .goBack)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "]", keyCode: 30, modifiers: [.command]), .goForward)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: nil, keyCode: 126, modifiers: [.command]), .goUp)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "r", keyCode: 15, modifiers: [.command]), .refresh)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: ".", keyCode: 47, modifiers: [.command, .shift]), .toggleHidden)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "n", keyCode: 45, modifiers: [.command]), .createFile)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "n", keyCode: 45, modifiers: [.command, .shift]), .createFolder)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "c", keyCode: 8, modifiers: [.command, .option]), .copyToOtherPane)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "v", keyCode: 9, modifiers: [.command, .option]), .moveToOtherPane)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "a", keyCode: 0, modifiers: [.command]), .selectAll)
    }

    func testPointerSelectionClearsOnlyPlainEmptyAreaClicks() {
        XCTAssertTrue(FileTablePointerSelection.shouldClearSelection(clickedRow: -1, modifiers: []))
        XCTAssertFalse(FileTablePointerSelection.shouldClearSelection(clickedRow: 0, modifiers: []))
        XCTAssertFalse(FileTablePointerSelection.shouldClearSelection(clickedRow: -1, modifiers: [.command]))
        XCTAssertFalse(FileTablePointerSelection.shouldClearSelection(clickedRow: -1, modifiers: [.shift]))
    }

    func testModifierClickSelectionSupportsCommandToggleAndShiftRange() {
        let commandAdded = FileTableSelectionReducer.selection(
            selectedRows: IndexSet(integer: 1),
            anchorRow: 1,
            clickedRow: 3,
            rowCount: 6,
            modifiers: [.command]
        )
        XCTAssertEqual(commandAdded.selectedRows, IndexSet([1, 3]))
        XCTAssertEqual(commandAdded.anchorRow, 3)

        let commandRemoved = FileTableSelectionReducer.selection(
            selectedRows: commandAdded.selectedRows,
            anchorRow: commandAdded.anchorRow,
            clickedRow: 1,
            rowCount: 6,
            modifiers: [.command]
        )
        XCTAssertEqual(commandRemoved.selectedRows, IndexSet(integer: 3))
        XCTAssertEqual(commandRemoved.anchorRow, 3)

        let shiftRange = FileTableSelectionReducer.selection(
            selectedRows: IndexSet(integer: 2),
            anchorRow: 2,
            clickedRow: 5,
            rowCount: 6,
            modifiers: [.shift]
        )
        XCTAssertEqual(shiftRange.selectedRows, IndexSet(integersIn: 2...5))
        XCTAssertEqual(shiftRange.anchorRow, 2)
    }

    func testTransferConflictDetectorFindsLocalNameCollisions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderTransferConflicts-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceFile = source.appendingPathComponent("same.txt")
        let destinationFile = destination.appendingPathComponent("same.txt")
        let uniqueFile = source.appendingPathComponent("unique.txt")
        try "source".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "destination".write(to: destinationFile, atomically: true, encoding: .utf8)
        try "unique".write(to: uniqueFile, atomically: true, encoding: .utf8)

        let provider = LocalFileProvider()
        let items = try await provider.list(.local(path: source.path), options: .init(showHiddenFiles: true, sort: .name(ascending: true)))
        let conflicts = TransferConflictDetector.conflicts(
            for: items,
            destination: .local(path: destination.path)
        )

        XCTAssertEqual(conflicts, [
            TransferConflict(itemName: "same.txt", destinationPath: destinationFile.path)
        ])
    }

    func testCopySelectionToOtherPanePromptsWhenLocalDestinationHasSameName() async throws {
        let fixture = try await makePendingOverwriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let app = AppModel()
        app.activePane = .left
        app.leftPane.location = .local(path: fixture.source.path)
        app.leftPane.items = [fixture.item]
        app.leftPane.selection = [fixture.item.id]
        app.rightPane.location = .local(path: fixture.destination.path)

        app.copySelectionToOtherPane(move: false)

        let pending = try XCTUnwrap(app.pendingTransferOverwrite)
        XCTAssertFalse(pending.move)
        XCTAssertEqual(pending.conflicts, [
            TransferConflict(itemName: "same.txt", destinationPath: fixture.destinationFile.path)
        ])
    }

    func testMoveSelectionToOtherPanePromptsWhenLocalDestinationHasSameName() async throws {
        let fixture = try await makePendingOverwriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let app = AppModel()
        app.activePane = .left
        app.leftPane.location = .local(path: fixture.source.path)
        app.leftPane.items = [fixture.item]
        app.leftPane.selection = [fixture.item.id]
        app.rightPane.location = .local(path: fixture.destination.path)

        app.copySelectionToOtherPane(move: true)

        let pending = try XCTUnwrap(app.pendingTransferOverwrite)
        XCTAssertTrue(pending.move)
        XCTAssertEqual(pending.conflicts, [
            TransferConflict(itemName: "same.txt", destinationPath: fixture.destinationFile.path)
        ])
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

    func testLocalPathCompletionSuggestsMatchingDirectoriesAndPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderPathCompletion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("Alpha.app", isDirectory: true)
        let folder = root.appendingPathComponent("Alpha Folder", isDirectory: true)
        let ignoredFile = root.appendingPathComponent("Alpha.txt")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "ignored".write(to: ignoredFile, atomically: true, encoding: .utf8)

        let suggestions = LocalPathCompletion.suggestions(
            for: root.appendingPathComponent("Al").path,
            relativeTo: root,
            limit: 5
        )

        XCTAssertEqual(suggestions, [folder.path, app.path].sorted())
    }

    func testLocalPathCompletionResolvesRelativeInputAgainstCurrentDirectory() {
        let base = URL(fileURLWithPath: "/tmp/open-finder-base", isDirectory: true)

        let resolved = LocalPathCompletion.resolvedPath("Child", relativeTo: base)

        XCTAssertEqual(resolved, "/tmp/open-finder-base/Child")
    }

    private struct PendingOverwriteFixture {
        let root: URL
        let source: URL
        let destination: URL
        let destinationFile: URL
        let item: FileItem
    }

    private func makePendingOverwriteFixture() async throws -> PendingOverwriteFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderPendingOverwrite-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceFile = source.appendingPathComponent("same.txt")
        let destinationFile = destination.appendingPathComponent("same.txt")
        try "source".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "destination".write(to: destinationFile, atomically: true, encoding: .utf8)
        let item = try await LocalFileProvider().stat(.local(path: sourceFile.path))
        return PendingOverwriteFixture(
            root: root,
            source: source,
            destination: destination,
            destinationFile: destinationFile,
            item: item
        )
    }
}
