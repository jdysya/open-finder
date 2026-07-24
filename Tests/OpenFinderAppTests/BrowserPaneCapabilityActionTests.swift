import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import OpenFinderApp
@testable import OpenFinderCore

@MainActor
final class BrowserPaneCapabilityActionTests: XCTestCase {
    func testActionsMatchEffectiveCapabilities() {
        let local = FileSourceID.local
        let webDAV = FileSourceID.remote(accountID: UUID(), connectorID: .webDAV)
        let kodbox = FileSourceID.remote(accountID: UUID(), connectorID: .kodbox)
        let scope = FileTagScope(
            id: "personal",
            kind: .personal,
            displayName: "Personal",
            capabilities: .init(canAssociate: true, canCreate: true, canRename: true, canDelete: true)
        )

        let cases: [(String, FileSourceID, Bool, Bool, Set<FileSourceOperation>)] = [
            ("local", local, true, true, Set(FileSourceOperation.allCases).subtracting([.delete])),
            ("webdav", webDAV, true, false, [
                .createFile, .createFolder, .rename, .delete, .quickLook, .open
            ]),
            ("kodbox", kodbox, true, true, [
                .createFile, .createFolder, .rename, .delete, .editTags, .quickLook, .open
            ])
        ]

        for (name, sourceID, writable, supportsTags, enabled) in cases {
            let location = FileLocation(
                sourceID: sourceID,
                path: .init(identifier: "/", displayPath: "/")
            )
            let adapter = BrowserPaneFileOperationAdapter(
                location: .resolved(location),
                listingCapabilities: .init(
                    source: .init(sourceID: sourceID),
                    isReadable: true,
                    isWritable: writable,
                    supportsTags: supportsTags
                )
            )
            let item = makeItem(
                sourceID: sourceID,
                writable: writable,
                supportsTags: supportsTags,
                scopes: supportsTags ? [scope] : []
            )

            for operation in FileSourceOperation.allCases {
                let items: [FileItem] = [.createFile, .createFolder].contains(operation) ? [] : [item]
                XCTAssertEqual(
                    adapter.decision(for: operation, items: items) == .allowed,
                    enabled.contains(operation),
                    "\(name) \(operation.rawValue)"
                )
            }
        }

        let rcloneID = UUID()
        let rclone = BrowserPaneFileOperationAdapter(
            location: .unsupported(.legacyRclone(remoteID: rcloneID)),
            listingCapabilities: nil
        )
        for operation in FileSourceOperation.allCases {
            XCTAssertEqual(
                rclone.decision(for: operation, items: []),
                .rejected(.legacyRclone(remoteID: rcloneID))
            )
        }
        print("ACTION_MATRIX providers=4 operations=\(FileSourceOperation.allCases.count) typed=true")
    }

    func testAdapterStillRejectsForgedUnsupportedAction() {
        let sourceID = FileSourceID.remote(accountID: UUID(), connectorID: .webDAV)
        let adapter = BrowserPaneFileOperationAdapter(
            location: .resolved(.init(
                sourceID: sourceID,
                path: .init(identifier: "/", displayPath: "/")
            )),
            listingCapabilities: .init(
                source: .init(sourceID: sourceID),
                isReadable: true,
                isWritable: true,
                supportsTags: false
            )
        )
        let item = makeItem(sourceID: sourceID, writable: true, supportsTags: false)
        let expected = FileCapabilityUnsupportedReason.operationUnsupported(
            sourceID: sourceID,
            capability: .tags
        )

        XCTAssertEqual(
            adapter.presentationState(for: .editTags, items: [item]),
            .disabled(expected)
        )
        XCTAssertThrowsError(try adapter.require(.editTags, items: [item])) {
            XCTAssertEqual($0 as? FileCapabilityUnsupportedReason, expected)
        }
        print("FORGED_ACTION uiReason=\(expected) adapterReason=\(expected) executed=false")
    }

    func testSupportedSourceTransferMenuActionsRemainEnabled() throws {
        let sources: [(String, FileSourceID, Bool)] = [
            ("local", .local, true),
            ("webdav", .remote(accountID: UUID(), connectorID: .webDAV), false),
            ("kodbox", .remote(accountID: UUID(), connectorID: .kodbox), true)
        ]

        for (name, sourceID, supportsTags) in sources {
            let item = makeItem(
                sourceID: sourceID,
                writable: true,
                supportsTags: supportsTags,
                scopes: supportsTags ? [.local] : []
            )
            let adapter = BrowserPaneFileOperationAdapter(
                location: item.location.fileLocation,
                listingCapabilities: .init(
                    source: .init(sourceID: sourceID),
                    isReadable: true,
                    isWritable: true,
                    supportsTags: supportsTags
                )
            )

            let menu = try XCTUnwrap(makeMenu(item: item, adapter: adapter))

            XCTAssertEqual(menu.item(withTitle: "Copy to Other Pane")?.isEnabled, true, name)
            XCTAssertEqual(menu.item(withTitle: "Move to Other Pane")?.isEnabled, true, name)
        }
    }

    func testSelectedLegacyRcloneDisablesTransferMenuActions() throws {
        let remoteID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let item = FileItem(
            id: "legacy-rclone-item",
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
        let expected = FileCapabilityUnsupportedReason.legacyRclone(remoteID: remoteID)

        let menu = try XCTUnwrap(makeMenu(item: item, adapter: adapter))

        for title in ["Copy to Other Pane", "Move to Other Pane"] {
            let action = try XCTUnwrap(menu.item(withTitle: title))
            XCTAssertFalse(action.isEnabled, title)
            XCTAssertEqual(action.toolTip, expected.localizedDescription, title)
        }
        let actionableItems = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertFalse(actionableItems.isEmpty)
        XCTAssertTrue(actionableItems.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(actionableItems.allSatisfy {
            $0.toolTip == expected.localizedDescription
        })
        for operation in FileSourceOperation.allCases {
            XCTAssertEqual(
                adapter.decision(for: operation, items: [item]),
                .rejected(expected),
                operation.rawValue
            )
        }
    }

    func testSelectedLegacyRcloneTransferActionIsDisabledAndRejectedAtAppBoundary() throws {
        let remoteID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
        let item = FileItem(
            id: "legacy-rclone-transfer-item",
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
        let app = AppModel(startAutomatically: false)
        app.leftPane.location = .rclone(remoteID: remoteID, path: "/")
        app.leftPane.items = [item]
        app.leftPane.selection = [item.id]
        let expected = FileCapabilityUnsupportedReason.legacyRclone(remoteID: remoteID)

        XCTAssertEqual(
            app.transferActionPresentationState(for: .copy),
            .disabled(expected)
        )

        app.performTransferAction(.copy)

        XCTAssertEqual(app.statusMessage, expected.localizedDescription)
        XCTAssertNil(app.pendingTransferOverwrite)
        XCTAssertTrue(app.taskRecords.isEmpty)
    }

    func testSupportedSourceTransferActionPresentationsRemainEnabled() {
        let sources: [(FileSourceID, Bool)] = [
            (.local, true),
            (.remote(accountID: UUID(), connectorID: .webDAV), false),
            (.remote(accountID: UUID(), connectorID: .kodbox), true)
        ]

        for (sourceID, supportsTags) in sources {
            let item = makeItem(
                sourceID: sourceID,
                writable: true,
                supportsTags: supportsTags,
                scopes: supportsTags ? [.local] : []
            )
            let app = AppModel(startAutomatically: false)
            app.leftPane.location = item.location
            app.leftPane.items = [item]
            app.leftPane.selection = [item.id]

            XCTAssertEqual(app.transferActionPresentationState(for: .copy), .enabled)
            XCTAssertEqual(app.transferActionPresentationState(for: .move), .enabled)
        }
    }

    private func makeItem(
        sourceID: FileSourceID,
        writable: Bool,
        supportsTags: Bool,
        scopes: [FileTagScope] = []
    ) -> FileItem {
        let location: Location
        switch sourceID {
        case .local:
            location = .local(path: "/tmp/report.txt")
        case .remote(let accountID, let connectorID):
            location = .remote(.init(
                accountID: accountID,
                connectorID: connectorID,
                path: .init(identifier: "/report.txt", displayPath: "/report.txt")
            ))
        }
        return FileItem(
            id: "item",
            name: "report.txt",
            location: location,
            kind: .file,
            size: 1,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: "text/plain",
            fileExtension: "txt",
            isHidden: false,
            isReadable: true,
            isWritable: writable,
            tagScopes: scopes,
            supportsTagEditing: supportsTags
        )
    }

    private func makeMenu(
        item: FileItem,
        adapter: BrowserPaneFileOperationAdapter
    ) -> NSMenu? {
        var selection: Set<String> = [item.id]
        let parent = FileTableRepresentable(
            items: [item],
            directorySizeText: [:],
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            onOpen: { _ in },
            onActivate: {},
            onDropFileURLs: { _ in },
            remoteFileDownloader: { _, _ in },
            pluginActionsForSelection: { _ in [] },
            presentationForAction: { action, items in
                switch action {
                case .copyToOtherPane, .moveToOtherPane:
                    adapter.presentationState(for: .open, items: items)
                case .open:
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
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
        return coordinator.makeMenu(tableView: table, row: 0)
    }
}
