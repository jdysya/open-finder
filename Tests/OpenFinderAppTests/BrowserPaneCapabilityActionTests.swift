import Foundation
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
}
