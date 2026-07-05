import Foundation
import XCTest
@testable import OpenFinderCore

final class LocalFileProviderTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderLocalTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    func testListsLocalDirectoryWithDirectoryFirstSortingAndHiddenFiltering() async throws {
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("Folder", isDirectory: true), withIntermediateDirectories: true)
        try "alpha".write(to: tempRoot.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        try "beta".write(to: tempRoot.appendingPathComponent("Beta.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: tempRoot.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let provider = LocalFileProvider()
        let items = try await provider.list(.local(path: tempRoot.path), options: .init(showHiddenFiles: false, sort: .name(ascending: true)))

        XCTAssertEqual(items.map(\.name), ["Folder", "alpha.md", "Beta.txt"])
        XCTAssertEqual(items.first?.kind, .directory)
        XCTAssertFalse(items.contains { $0.name == ".hidden" })
        XCTAssertEqual(FileBrowserFilter.apply(items, text: "ALP").map(\.name), ["alpha.md"])
    }

    func testCreatesRenamesCopiesAndMovesLocalFiles() async throws {
        let provider = LocalFileProvider()
        let root = Location.local(path: tempRoot.path)

        try await provider.createFolder(at: root, name: "Created")
        try await provider.createFile(at: root, name: "note.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("Created").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("note.txt").path))

        var items = try await provider.list(root, options: .init(showHiddenFiles: true, sort: .name(ascending: true)))
        let note = try XCTUnwrap(items.first { $0.name == "note.txt" })
        let renamed = try await provider.rename(note, to: "renamed.txt")
        XCTAssertEqual(renamed.name, "renamed.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("renamed.txt").path))

        let destination = tempRoot.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let destinationLocation = Location.local(path: destination.path)
        _ = try await provider.copy([renamed], to: destinationLocation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("renamed.txt").path))

        items = try await provider.list(root, options: .init(showHiddenFiles: true, sort: .name(ascending: true)))
        let created = try XCTUnwrap(items.first { $0.name == "Created" })
        _ = try await provider.move([created], to: destinationLocation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Created").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("Created").path))
    }
    func testTrashFailureDoesNotPermanentlyDeleteItem() async throws {
        let file = tempRoot.appendingPathComponent("keep.txt")
        try "keep".write(to: file, atomically: true, encoding: .utf8)
        let provider = LocalFileProvider(trashItem: { _ in throw OpenFinderError.operationFailed("Trash unavailable") })
        let item = try await provider.stat(.local(path: file.path))

        do {
            try await provider.trashOrDelete([item])
            XCTFail("Expected trash failure")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Trash failure must not fall back to permanent deletion")
        }
    }

}
