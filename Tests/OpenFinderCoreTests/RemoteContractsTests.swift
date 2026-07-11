import Foundation
import XCTest
@testable import OpenFinderCore

final class RemoteContractsTests: XCTestCase {
    func testRemoteLocationRoundTripsOpaqueIdentifierAndDisplayPath() throws {
        let location = Location.remote(
            RemoteLocation(
                accountID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                connectorID: RemoteConnectorID(rawValue: "opaque"),
                path: RemotePath(identifier: "{source:99}/", displayPath: "/Personal Space/Projects")
            )
        )

        let decoded = try JSONDecoder().decode(Location.self, from: JSONEncoder().encode(location))

        XCTAssertEqual(decoded, location)
        XCTAssertEqual(decoded.displayPath, "opaque:/Personal Space/Projects")
    }

    func testListingUsesProviderSuppliedParentForNonHierarchicalIdentifier() async throws {
        let child = RemotePath(identifier: "{source:99}/", displayPath: "/Personal Space/Child")
        let suppliedParent = RemotePath(identifier: "{source:5}/", displayPath: "/Personal Space")
        let item = RemoteItem(
            id: "child",
            name: "Child",
            path: child,
            kind: .directory,
            size: nil,
            modificationDate: nil,
            etag: nil,
            mimeType: nil,
            isReadable: true,
            isWritable: false
        )
        let provider = FixtureRemoteProvider(
            listing: RemoteDirectoryListing(
                current: child,
                parent: suppliedParent,
                items: [item],
                capabilities: .init(isReadable: true, isWritable: false)
            )
        )

        let listing = try await provider.list(directory: child)

        XCTAssertEqual(listing.current.identifier, "{source:99}/")
        XCTAssertEqual(listing.parent?.identifier, "{source:5}/")
        XCTAssertEqual(listing.parent?.displayPath, "/Personal Space")
        XCTAssertEqual(listing.items.single?.remotePath.identifier, "{source:99}/")
        XCTAssertTrue(listing.items.single?.isReadable ?? false)
        XCTAssertFalse(listing.items.single?.isWritable ?? true)
        XCTAssertFalse(listing.capabilities.isWritable)
    }
}

private actor FixtureRemoteProvider: RemoteProvider {
    private let listing: RemoteDirectoryListing

    init(listing: RemoteDirectoryListing) {
        self.listing = listing
    }

    func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        listing
    }

    func createDirectory(in parent: RemotePath, named name: String) async throws {}

    func delete(item: RemotePath) async throws {}

    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {}

    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {}

    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID {
        UUID()
    }

    func download(item: RemotePath, to localURL: URL) async throws -> TaskID {
        UUID()
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
