import Foundation
import XCTest
@testable import OpenFinderCore

final class LocationMigrationIntegrationTests: XCTestCase {
    private let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let rcloneID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testGoldenLocationsDecodeRoundTripAndNormalizeThroughRegistry() async throws {
        let registry = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { _, _ in
                LocationMigrationRemoteProvider()
            }
        )

        let legacyLocal = try decodeFixture("legacy-local")
        let legacyWebDAV = try decodeFixture("legacy-webdav")
        let canonicalRemote = try decodeFixture("canonical-remote")

        XCTAssertEqual(legacyLocal, .local(path: "/Users/example/Documents"))
        XCTAssertEqual(
            try registry.normalizedLocation(legacyLocal),
            .local(path: "/Users/example/Documents")
        )
        XCTAssertEqual(
            try registry.normalizedLocation(legacyWebDAV),
            .remote(.init(
                accountID: accountID,
                connectorID: .webDAV,
                path: .init(identifier: "/Archive", displayPath: "/Archive")
            ))
        )
        XCTAssertEqual(try registry.normalizedLocation(canonicalRemote), canonicalRemote)

        for fixture in ["legacy-local", "legacy-webdav", "legacy-rclone", "canonical-remote"] {
            let original = try fixtureData(fixture)
            let decoded = try JSONDecoder().decode(Location.self, from: original)
            let encoded = try JSONEncoder.sorted.encode(decoded)
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
                try JSONSerialization.jsonObject(with: original) as? NSDictionary,
                "Location golden round-trip changed for \(fixture)"
            )
        }
    }

    func testLegacyRcloneRemainsExactTypedUnsupported() async throws {
        let registry = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { _, _ in
                LocationMigrationRemoteProvider()
            }
        )
        let legacyRclone = try decodeFixture("legacy-rclone")

        XCTAssertThrowsError(try registry.normalizedLocation(legacyRclone)) { error in
            XCTAssertEqual(
                error as? FileCapabilityUnsupportedReason,
                .legacyRclone(remoteID: self.rcloneID)
            )
        }
        do {
            _ = try await registry.resolve(legacyRclone)
            XCTFail("Expected legacy rclone to remain unsupported")
        } catch let error as FileCapabilityUnsupportedReason {
            XCTAssertEqual(error, .legacyRclone(remoteID: rcloneID))
        }
    }

    func testPluginInputSnapshotsUseNormalizedLocations() throws {
        let registry = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { _, _ in
                LocationMigrationRemoteProvider()
            }
        )
        let legacyLocation = try decodeFixture("legacy-webdav")
        let snapshot = PluginTaskInputSnapshot(
            location: try registry.normalizedLocation(legacyLocation),
            identity: .init(
                id: "fixture",
                name: "fixture.txt",
                kind: .file,
                size: 14,
                modificationDate: nil,
                uti: nil,
                mimeType: "text/plain",
                fileExtension: "txt"
            )
        )

        XCTAssertEqual(
            snapshot.location,
            .remote(.init(
                accountID: accountID,
                connectorID: .webDAV,
                path: .init(identifier: "/Archive", displayPath: "/Archive")
            ))
        )
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
            .contains(#""type":"webDAV""#))
    }

    func testAdapterRoutesListingParentMutationsTagsDragAndMaterialization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocationMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = LocationMigrationRemoteProvider()
        let registry = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { _, revision in
                XCTAssertEqual(revision, "fixture-r1")
                return provider
            },
            materializationRoot: root
        )
        let location = try decodeFixture("legacy-webdav")
        let source = try await registry.resolve(location, revision: "fixture-r1")

        let listing = try await source.list(options: .init())
        XCTAssertEqual(listing.items.map(\.name), ["fixture.txt"])
        XCTAssertEqual(
            listing.parent,
            .remote(.init(
                accountID: accountID,
                connectorID: .webDAV,
                path: .init(identifier: "/", displayPath: "/")
            ))
        )
        try await source.createFolder(named: "Folder")
        try await source.createFile(named: "Empty.txt")
        let item = try XCTUnwrap(listing.items.first)
        try await source.rename(item, to: "Renamed.txt", in: source)
        try await source.delete(item)
        XCTAssertNotNil(source.tagProvider)

        let dragged = root.appendingPathComponent("dragged.txt")
        try await source.download(item, to: dragged)
        XCTAssertEqual(try Data(contentsOf: dragged), Data("remote-fixture".utf8))

        let lease = try await registry.materialize(
            item.location,
            revision: "fixture-r1",
            requestID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("remote-fixture".utf8))
        try lease.release()

        let events = await provider.events
        XCTAssertEqual(
            events,
            [
                "list:/Archive",
                "mkdir:/Archive/Folder",
                "upload:/Archive/Empty.txt:0",
                "move:/Archive/fixture.txt:/Archive/Renamed.txt",
                "delete:/Archive/fixture.txt",
                "download:/Archive/fixture.txt",
                "download:/Archive/fixture.txt"
            ]
        )
    }

    private func decodeFixture(_ name: String) throws -> Location {
        try JSONDecoder().decode(Location.self, from: fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/LocationMigration/\(name).json")
        return try Data(contentsOf: url)
    }
}

private actor LocationMigrationRemoteProvider: RemoteProvider, TagProvider {
    private(set) var events: [String] = []

    func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        events.append("list:\(directory.identifier)")
        return .init(
            current: directory,
            parent: .init(identifier: "/", displayPath: "/"),
            items: [.init(
                id: "fixture",
                name: "fixture.txt",
                path: .init(
                    identifier: "\(directory.identifier)/fixture.txt",
                    displayPath: "\(directory.displayPath)/fixture.txt"
                ),
                kind: .file,
                size: 14,
                modificationDate: nil,
                etag: nil,
                mimeType: "text/plain",
                isReadable: true,
                isWritable: true,
                supportsTagEditing: true
            )],
            capabilities: .init(isReadable: true, isWritable: true, supportsTags: true)
        )
    }

    func createDirectory(in parent: RemotePath, named name: String) async throws {
        events.append("mkdir:\(parent.identifier)/\(name)")
    }

    func delete(item: RemotePath) async throws {
        events.append("delete:\(item.identifier)")
    }

    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {
        events.append("move:\(item.identifier):\(destination.identifier)/\(name)")
    }

    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {}

    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID {
        events.append(
            "upload:\(parent.identifier)/\(name):\((try? Data(contentsOf: localURL).count) ?? -1)"
        )
        return UUID()
    }

    func download(item: RemotePath, to localURL: URL) async throws -> TaskID {
        events.append("download:\(item.identifier)")
        try Data("remote-fixture".utf8).write(to: localURL)
        return UUID()
    }

    func tagCatalog(for location: Location) async throws -> FileTagCatalog {
        .init(scopes: [.local])
    }

    func apply(_ changes: FileTagChangeSet, to items: [FileItem]) async throws -> TagApplyResult {
        .init(appliedItemIDs: items.map(\.id))
    }

    func mutate(
        _ mutation: FileTagCatalogMutation,
        in scope: FileTagScope
    ) async throws -> FileTagCatalog {
        .init(scopes: [scope])
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
