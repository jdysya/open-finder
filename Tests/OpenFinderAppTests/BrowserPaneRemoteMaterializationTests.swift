import Foundation
import XCTest
@testable import OpenFinderApp
@testable import OpenFinderCore

@MainActor
final class BrowserPaneRemoteMaterializationTests: XCTestCase {
    func testRemoteMaterializationRetainsDistinctRegistryLeasesForSameNamedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderBrowserMaterialization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = BrowserPaneMaterializationProvider()
        let registry = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { _, _ in provider },
            materializationRoot: root
        )
        let firstAccount = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondAccount = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var pane: BrowserPaneModel? = BrowserPaneModel(
            id: .left,
            location: remoteLocation(accountID: firstAccount, identifier: "{source:one}"),
            remoteProviderResolver: { _ in provider },
            fileSourceRegistry: registry,
            providerRevisionResolver: { _ in "r1" }
        )
        let first = remoteFile(accountID: firstAccount, identifier: "{source:one}/movie.mp4", id: "first")
        let second = remoteFile(accountID: secondAccount, identifier: "{source:two}/movie.mp4", id: "second")

        let firstURL = try await pane?.materializeRemoteFile(first)
        let secondURL = try await pane?.materializeRemoteFile(second)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(firstURL)), Data(first.id.utf8))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(secondURL)), Data(second.id.utf8))
        pane = nil
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func remoteLocation(
        accountID: UUID,
        identifier: String,
        displayPath: String = "/"
    ) -> Location {
        .remote(.init(
            accountID: accountID,
            connectorID: .kodbox,
            path: .init(identifier: identifier, displayPath: displayPath)
        ))
    }

    private func remoteFile(accountID: UUID, identifier: String, id: String) -> FileItem {
        FileItem(
            id: id,
            name: "movie.mp4",
            location: remoteLocation(
                accountID: accountID,
                identifier: identifier,
                displayPath: "/\(id)/movie.mp4"
            ),
            kind: .file,
            size: nil,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: "video/mp4",
            fileExtension: "mp4",
            isHidden: false,
            isReadable: true,
            isWritable: false
        )
    }
}

private actor BrowserPaneMaterializationProvider: RemoteProvider {
    func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        .init(
            current: directory,
            parent: nil,
            items: [],
            capabilities: .init(isReadable: true, isWritable: true)
        )
    }

    func createDirectory(in parent: RemotePath, named name: String) async throws {}
    func delete(item: RemotePath) async throws {}
    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID { UUID() }

    func download(item: RemotePath, to localURL: URL) async throws -> TaskID {
        let identifier = item.identifier.hasPrefix("{source:one}") ? "first" : "second"
        try Data(identifier.utf8).write(to: localURL)
        return UUID()
    }
}
