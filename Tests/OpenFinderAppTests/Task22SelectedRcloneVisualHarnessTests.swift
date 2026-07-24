import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import OpenFinderApp
@testable import OpenFinderCore

@MainActor
final class Task22SelectedRcloneVisualHarnessTests: XCTestCase {
    func testCaptureSelectedRcloneMenu() throws {
        let remoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let item = FileItem(
            id: "selected-rclone-item",
            name: "report.txt",
            location: .rclone(remoteID: remoteID, path: "/report.txt"),
            kind: .file,
            size: 1,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: "text/plain",
            fileExtension: "txt",
            isHidden: false,
            isReadable: true,
            isWritable: true
        )
        let adapter = BrowserPaneFileOperationAdapter(
            location: item.location.fileLocation,
            listingCapabilities: nil
        )
        let menu = try XCTUnwrap(makeMenu(item: item, adapter: adapter))
        let copy = try XCTUnwrap(menu.item(withTitle: "Copy to Other Pane"))
        let move = try XCTUnwrap(menu.item(withTitle: "Move to Other Pane"))
        let expected = FileCapabilityUnsupportedReason.legacyRclone(remoteID: remoteID)

        XCTAssertFalse(copy.isEnabled)
        XCTAssertFalse(move.isEnabled)
        XCTAssertEqual(copy.toolTip, expected.localizedDescription)
        XCTAssertEqual(move.toolTip, expected.localizedDescription)

        let outputDirectory = try artifactDirectory()
        let imageURL = outputDirectory.appendingPathComponent("selected-rclone-menu.png")
        let snapshotURL = outputDirectory.appendingPathComponent("selected-rclone-menu.json")
        try render(
            item: item,
            reason: expected.localizedDescription,
            copyEnabled: copy.isEnabled,
            moveEnabled: move.isEnabled,
            to: imageURL
        )
        let snapshot = MenuSnapshot(
            selectedItem: item.name,
            selectedSource: "legacy-rclone",
            copyEnabled: copy.isEnabled,
            moveEnabled: move.isEnabled,
            disabledReason: expected.localizedDescription
        )
        let snapshotData = try JSONEncoder.openFinder.encode(snapshot)
        try snapshotData.write(to: snapshotURL, options: .atomic)

        XCTAssertGreaterThan(try Data(contentsOf: imageURL).count, 0)
        XCTAssertGreaterThan(try Data(contentsOf: snapshotURL).count, 0)
        print("TASK22_VISUAL_HARNESS image=\(imageURL.path) snapshot=\(snapshotURL.path)")
    }

    private func artifactDirectory() throws -> URL {
        let configured = ProcessInfo.processInfo.environment["TASK22_EVIDENCE_DIR"]
        let directory = configured.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "openfinder-task22-visual-harness",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func render(
        item: FileItem,
        reason: String,
        copyEnabled: Bool,
        moveEnabled: Bool,
        to destination: URL
    ) throws {
        let image = NSImage(size: .init(width: 760, height: 210))
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: .init(x: 0, y: 0, width: 760, height: 210)).fill()
        let lines = [
            "Selected: \(item.name) (legacy rclone)",
            "Copy to Other Pane: \(copyEnabled ? "enabled" : "disabled")",
            "Move to Other Pane: \(moveEnabled ? "enabled" : "disabled")",
            "Reason: \(reason)"
        ]
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: index == 0 ? NSColor.labelColor : NSColor.disabledControlTextColor
            ]
            line.draw(at: .init(x: 24, y: 170 - index * 42), withAttributes: attributes)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw HarnessError.imageEncodingFailed
        }
        try png.write(to: destination, options: .atomic)
    }

    private func makeMenu(
        item: FileItem,
        adapter: BrowserPaneFileOperationAdapter
    ) -> NSMenu? {
        var selection: Set<String> = [item.id]
        let parent = FileTableRepresentable(
            items: [item],
            directorySizeText: [:],
            selection: Binding(get: { selection }, set: { selection = $0 }),
            onOpen: { _ in },
            onActivate: {},
            onDropFileURLs: { _ in },
            remoteFileDownloader: { _, _ in },
            pluginActionsForSelection: { _ in [] },
            presentationForAction: { action, items in
                switch action {
                case .copyToOtherPane, .moveToOtherPane, .open:
                    adapter.presentationState(for: .open, items: items)
                case .editTags:
                    adapter.presentationState(for: .editTags, items: items)
                case .rename:
                    adapter.presentationState(for: .rename, items: items)
                case .trash:
                    adapter.presentationState(for: .trash, items: items)
                case .revealInFinder:
                    adapter.presentationState(for: .revealInFinder, items: items)
                case .openInTerminal:
                    adapter.presentationState(for: .openInTerminal, items: items)
                case .quickLook:
                    adapter.presentationState(for: .quickLook, items: items)
                case .createFile, .createFolder, .goBack, .goForward, .goUp,
                     .refresh, .toggleHidden, .selectAll, .plugin:
                    nil
                }
            },
            onAction: { _, _ in }
        )
        let coordinator = FileTableRepresentable.Coordinator(parent)
        let table = NSTableView()
        table.dataSource = coordinator
        table.delegate = coordinator
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        return coordinator.makeMenu(tableView: table, row: 0)
    }
}

private struct MenuSnapshot: Codable {
    let selectedItem: String
    let selectedSource: String
    let copyEnabled: Bool
    let moveEnabled: Bool
    let disabledReason: String
}

private enum HarnessError: Error {
    case imageEncodingFailed
}
