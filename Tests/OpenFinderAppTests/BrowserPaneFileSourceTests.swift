import Foundation
import XCTest
@testable import OpenFinderApp
@testable import OpenFinderCore

@MainActor
final class BrowserPaneFileSourceTests: XCTestCase {
    func testListingCarriesEffectiveCapabilities() async throws {
        let accountID = UUID()
        let directory = RemotePath(identifier: "opaque:child", displayPath: "/Child")
        let parent = RemotePath(identifier: "opaque:parent", displayPath: "/")
        let itemPath = RemotePath(identifier: "opaque:item", displayPath: "/Child/report.txt")
        let provider = BrowserPaneFileSourceProvider(listing: .init(
            current: directory,
            parent: parent,
            items: [.init(
                id: "report",
                name: "report.txt",
                path: itemPath,
                kind: .file,
                size: 42,
                modificationDate: Date(timeIntervalSince1970: 123),
                etag: "etag-1",
                mimeType: "text/plain",
                isReadable: true,
                isWritable: false,
                supportsTagEditing: false
            )],
            capabilities: .init(
                isReadable: true,
                isWritable: false,
                supportsTags: true
            )
        ))
        let registry = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { _, revision in
                XCTAssertEqual(revision, "provider-r1")
                return provider
            }
        )
        let location = Location.remote(.init(
            accountID: accountID,
            connectorID: .kodbox,
            path: directory
        ))
        let pane = BrowserPaneModel(
            id: .left,
            location: location,
            remoteProviderResolver: { _ in provider },
            fileSourceRegistry: registry,
            providerRevisionResolver: { _ in "provider-r1" }
        )

        await pane.refresh()

        XCTAssertEqual(
            pane.locationCapabilities,
            FileSourceCapabilities(sourceID: .remote(
                accountID: accountID,
                connectorID: .kodbox
            ))
        )
        XCTAssertEqual(
            pane.listingCapabilities,
            FileListingCapabilities(
                source: try XCTUnwrap(pane.locationCapabilities),
                isReadable: true,
                isWritable: false,
                supportsTags: true
            )
        )
        XCTAssertEqual(pane.listingProviderRevision, "provider-r1")
        XCTAssertEqual(pane.remoteParent, parent)
        XCTAssertEqual(pane.items.first?.location, Location.remote(.init(
            accountID: accountID,
            connectorID: .kodbox,
            path: itemPath
        )))
        XCTAssertEqual(pane.items.first?.size, 42)
        XCTAssertEqual(pane.items.first?.mimeType, "text/plain")
        XCTAssertEqual(pane.items.first?.isReadable, true)
        XCTAssertEqual(pane.items.first?.isWritable, false)
        print(
            "BROWSER_FILE_SOURCE revision=\(pane.listingProviderRevision ?? "nil") " +
            "readable=\(pane.listingCapabilities?.isReadable == true) " +
            "writable=\(pane.listingCapabilities?.isWritable == true) " +
            "items=\(pane.items.map(\.name)) parent=\(pane.remoteParent?.identifier ?? "nil")"
        )
    }

    func testStaleCapabilityResponseIsDiscarded() async throws {
        let accountID = UUID()
        let directory = RemotePath(identifier: "opaque:directory", displayPath: "/")
        let oldParent = RemotePath(identifier: "opaque:old-parent", displayPath: "/Old")
        let newParent = RemotePath(identifier: "opaque:new-parent", displayPath: "/New")
        let oldProvider = BrowserPaneSuspendingFileSourceProvider(listing: .init(
            current: directory,
            parent: oldParent,
            items: [Self.remoteItem(id: "old", directory: directory)],
            capabilities: .init(
                isReadable: false,
                isWritable: false,
                supportsTags: false
            )
        ))
        let newProvider = BrowserPaneFileSourceProvider(listing: .init(
            current: directory,
            parent: newParent,
            items: [Self.remoteItem(id: "new", directory: directory)],
            capabilities: .init(
                isReadable: true,
                isWritable: true,
                supportsTags: true
            )
        ))
        let revision = BrowserPaneProviderRevision("provider-r1")
        let registry = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { _, requestedRevision in
                if requestedRevision == "provider-r1" {
                    return oldProvider
                }
                return newProvider
            }
        )
        let location = Location.remote(.init(
            accountID: accountID,
            connectorID: .kodbox,
            path: directory
        ))
        let pane = BrowserPaneModel(
            id: .right,
            location: location,
            remoteProviderResolver: { _ in newProvider },
            fileSourceRegistry: registry,
            providerRevisionResolver: { _ in await revision.value }
        )

        let staleRefresh = Task { @MainActor in await pane.refresh() }
        await oldProvider.waitUntilListingStarts()

        await revision.set("provider-r2")
        await pane.refresh()
        await oldProvider.resume()
        await staleRefresh.value

        XCTAssertEqual(pane.listingProviderRevision, "provider-r2")
        XCTAssertEqual(pane.listingCapabilities?.isReadable, true)
        XCTAssertEqual(pane.listingCapabilities?.isWritable, true)
        XCTAssertEqual(pane.listingCapabilities?.supportsTags, true)
        XCTAssertEqual(pane.items.map(\.name), ["new.txt"])
        XCTAssertEqual(pane.remoteParent, newParent)
        XCTAssertFalse(pane.isLoading)
        XCTAssertNil(pane.errorMessage)
        XCTAssertEqual(pane.listingGeneration, 2)
        print(
            "BROWSER_STALE_REJECTED revision=\(pane.listingProviderRevision ?? "nil") " +
            "generation=\(pane.listingGeneration) items=\(pane.items.map(\.name)) " +
            "parent=\(pane.remoteParent?.identifier ?? "nil") loading=\(pane.isLoading)"
        )
    }

    private static func remoteItem(id: String, directory: RemotePath) -> RemoteItem {
        RemoteItem(
            id: id,
            name: "\(id).txt",
            path: .init(
                identifier: "\(directory.identifier):\(id)",
                displayPath: "\(directory.displayPath)\(id).txt"
            ),
            kind: .file,
            size: nil,
            modificationDate: nil,
            etag: nil,
            mimeType: nil,
            isReadable: true,
            isWritable: true
        )
    }
}

private actor BrowserPaneProviderRevision {
    private var revision: String

    init(_ revision: String) {
        self.revision = revision
    }

    var value: String { revision }

    func set(_ revision: String) {
        self.revision = revision
    }
}

private actor BrowserPaneFileSourceProvider: RemoteProvider {
    private let listing: RemoteDirectoryListing

    init(listing: RemoteDirectoryListing) {
        self.listing = listing
    }

    func list(directory: RemotePath) async throws -> RemoteDirectoryListing { listing }
    func createDirectory(in parent: RemotePath, named name: String) async throws {}
    func delete(item: RemotePath) async throws {}
    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID { UUID() }
    func download(item: RemotePath, to localURL: URL) async throws -> TaskID { UUID() }
}

private actor BrowserPaneSuspendingFileSourceProvider: RemoteProvider {
    private let listing: RemoteDirectoryListing
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var listingContinuation: CheckedContinuation<Void, Never>?

    init(listing: RemoteDirectoryListing) {
        self.listing = listing
    }

    func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { listingContinuation = $0 }
        return listing
    }

    func waitUntilListingStarts() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        listingContinuation?.resume()
        listingContinuation = nil
    }

    func createDirectory(in parent: RemotePath, named name: String) async throws {}
    func delete(item: RemotePath) async throws {}
    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID { UUID() }
    func download(item: RemotePath, to localURL: URL) async throws -> TaskID { UUID() }
}
