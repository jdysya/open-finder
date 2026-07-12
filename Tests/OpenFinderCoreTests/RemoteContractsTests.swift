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

    func testRemoteItemRoundTripsScopedTagMetadata() throws {
        let scope = FileTagScope(
            id: "kodbox:team:42",
            kind: .team,
            displayName: "Design Team",
            capabilities: .init(canAssociate: true, canCreate: true, canRename: true)
        )
        let tag = FileTag(
            id: "17",
            scopeID: scope.id,
            name: "Release",
            color: .purple
        )
        let item = RemoteItem(
            id: "kodbox:{source:99}/release-notes.md",
            name: "release-notes.md",
            path: .init(identifier: "{source:99}/release-notes.md", displayPath: "/Design/release-notes.md"),
            kind: .file,
            size: 128,
            modificationDate: nil,
            etag: "etag-1",
            mimeType: "text/markdown",
            isReadable: true,
            isWritable: true,
            tags: [tag],
            tagScopes: [scope],
            supportsTagEditing: true
        )

        let decoded = try JSONDecoder().decode(RemoteItem.self, from: JSONEncoder().encode(item))

        XCTAssertEqual(decoded.tags, [tag])
        XCTAssertEqual(decoded.tagScopes, [scope])
        XCTAssertTrue(decoded.supportsTagEditing)
    }

    func testLegacyRemoteItemDecodingDefaultsToUnsupportedTagMetadata() throws {
        let data = Data(
            """
            {
              "id": "legacy-item",
              "name": "legacy.txt",
              "path": "/Legacy/legacy.txt",
              "remotePath": {"identifier": "{source:5}/legacy.txt", "displayPath": "/Legacy/legacy.txt"},
              "kind": "file",
              "size": 42,
              "modificationDate": null,
              "etag": null,
              "mimeType": "text/plain",
              "isReadable": true,
              "isWritable": false
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(RemoteItem.self, from: data)

        XCTAssertEqual(decoded.tags, [])
        XCTAssertEqual(decoded.tagScopes, [])
        XCTAssertFalse(decoded.supportsTagEditing)
    }

    func testDirectoryCapabilitiesDefaultToUnsupportedTags() throws {
        let capabilities = RemoteDirectoryCapabilities(isReadable: true, isWritable: true)
        let decoded = try JSONDecoder().decode(
            RemoteDirectoryCapabilities.self,
            from: Data("{\"isReadable\":true,\"isWritable\":true}".utf8)
        )

        XCTAssertFalse(capabilities.supportsTags)
        XCTAssertFalse(decoded.supportsTags)
    }

    func testWebDAVDoesNotConformToTagProvider() {
        let account = RemoteAccount(
            name: "WebDAV",
            provider: .webDAV,
            baseURL: URL(string: "https://webdav.test/")!,
            username: "alice",
            secretKeychainRef: nil,
            options: ["connectorID": RemoteConnectorID.webDAV.rawValue]
        )
        let provider = WebDAVProvider(account: account, credentialStore: InMemoryKeychainStore())

        XCTAssertNil(provider as? any TagProvider)
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
