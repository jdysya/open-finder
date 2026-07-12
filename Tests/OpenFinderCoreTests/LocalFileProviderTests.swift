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

    func testListAndStatReadFinderTags() async throws {
        let file = tempRoot.appendingPathComponent("tagged.txt")
        let folder = tempRoot.appendingPathComponent("Tagged Folder", isDirectory: true)
        try Data().write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try (file as NSURL).setResourceValue(["Important", "客户"], forKey: .tagNamesKey)
        try (folder as NSURL).setResourceValue(["Folder Tag"], forKey: .tagNamesKey)

        let provider = LocalFileProvider()
        let listed = try await provider.list(
            .local(path: tempRoot.path),
            options: .init(showHiddenFiles: true, sort: .name(ascending: true))
        )
        let listedFile = try XCTUnwrap(listed.first { $0.name == file.lastPathComponent })
        let listedFolder = try XCTUnwrap(listed.first { $0.name == folder.lastPathComponent })
        let stated = try await provider.stat(.local(path: file.path))

        XCTAssertEqual(listedFile.tags.map(\.name), ["Important", "客户"])
        XCTAssertEqual(listedFolder.tags.map(\.name), ["Folder Tag"])
        XCTAssertEqual(stated.tags.map(\.name), ["Important", "客户"])
        XCTAssertEqual(stated.tagScopes, [.local])
        XCTAssertTrue(stated.supportsTagEditing)
    }

    func testApplyTagChangesAddsAndRemovesWithoutDroppingUnrelatedTags() async throws {
        let file = tempRoot.appendingPathComponent("tagged.txt")
        try Data().write(to: file)
        try (file as NSURL).setResourceValue(["Keep", "Remove"], forKey: .tagNamesKey)

        let provider = LocalFileProvider()
        let item = try await provider.stat(.local(path: file.path))
        let result = try await provider.apply(
            FileTagChangeSet(
                add: [.local(name: "Added"), .local(name: "Added")],
                remove: [.local(name: "Remove")]
            ),
            to: [item]
        )

        XCTAssertEqual(result.appliedItemIDs, [item.id])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try tagNames(of: file), ["Keep", "Added"])
    }

    func testConcurrentTagAdditionsPreserveAllNames() async throws {
        let file = tempRoot.appendingPathComponent("tagged.txt")
        try Data().write(to: file)
        try (file as NSURL).setResourceValue(["Keep"], forKey: .tagNamesKey)

        let provider = LocalFileProvider()
        let item = try await provider.stat(.local(path: file.path))
        async let first = provider.apply(.init(add: [.local(name: "A")]), to: [item])
        async let second = provider.apply(.init(add: [.local(name: "B")]), to: [item])
        let (firstResult, secondResult) = try await (first, second)

        XCTAssertEqual(firstResult.appliedItemIDs, [item.id])
        XCTAssertEqual(secondResult.appliedItemIDs, [item.id])
        XCTAssertEqual(Set(try tagNames(of: file)), Set(["Keep", "A", "B"]))
    }

    func testApplyTagChangesSupportsTaggedFoldersAndLeavesEmptyChangesUntouched() async throws {
        let folder = tempRoot.appendingPathComponent("tagged", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try (folder as NSURL).setResourceValue(["Folder Tag"], forKey: .tagNamesKey)

        let provider = LocalFileProvider()
        let item = try await provider.stat(.local(path: folder.path))
        let noOp = try await provider.apply(.init(), to: [item])

        XCTAssertTrue(noOp.appliedItemIDs.isEmpty)
        XCTAssertTrue(noOp.failures.isEmpty)
        XCTAssertEqual(try tagNames(of: folder), ["Folder Tag"])

        let applied = try await provider.apply(
            .init(add: [.local(name: "Added")], remove: [.local(name: "Folder Tag")]),
            to: [item]
        )

        XCTAssertEqual(applied.appliedItemIDs, [item.id])
        XCTAssertEqual(try tagNames(of: folder), ["Added"])
    }

    func testApplyTagChangesReportsRemoteAndReadOnlyItemsWithoutMutatingThem() async throws {
        let file = tempRoot.appendingPathComponent("tagged.txt")
        try Data().write(to: file)
        try (file as NSURL).setResourceValue(["Keep"], forKey: .tagNamesKey)
        let provider = LocalFileProvider()
        let remote = makeItem(
            id: "remote:1",
            location: .remote(
                RemoteLocation(
                    accountID: UUID(),
                    connectorID: .webDAV,
                    path: RemotePath(identifier: "/item", displayPath: "/item")
                )
            ),
            isWritable: true
        )
        let readOnly = makeItem(
            id: "local:readonly",
            location: .local(path: file.path),
            isWritable: false
        )

        let result = try await provider.apply(.init(add: [.local(name: "Added")]), to: [remote, readOnly])

        XCTAssertTrue(result.appliedItemIDs.isEmpty)
        XCTAssertEqual(result.failures.map(\.itemID), [remote.id, readOnly.id])
        XCTAssertEqual(try tagNames(of: file), ["Keep"])
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

    func testLocalCopyAndMoveCanOverwriteExistingDestinationWhenExplicitlyAllowed() async throws {
        let provider = LocalFileProvider()
        let root = Location.local(path: tempRoot.path)
        let destination = tempRoot.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceFile = tempRoot.appendingPathComponent("same.txt")
        let destinationFile = destination.appendingPathComponent("same.txt")
        try "new".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "old".write(to: destinationFile, atomically: true, encoding: .utf8)
        let sourceItem = try await provider.stat(.local(path: sourceFile.path))

        do {
            _ = try await provider.copy([sourceItem], to: .local(path: destination.path))
            XCTFail("Copy should reject overwrite unless explicitly allowed")
        } catch {
            XCTAssertEqual(try String(contentsOf: destinationFile, encoding: .utf8), "old")
        }

        _ = try await provider.copy([sourceItem], to: .local(path: destination.path), overwriteExisting: true)
        XCTAssertEqual(try String(contentsOf: destinationFile, encoding: .utf8), "new")

        try "moved".write(to: sourceFile, atomically: true, encoding: .utf8)
        let moveItem = try await provider.stat(.local(path: sourceFile.path))
        _ = try await provider.move([moveItem], to: .local(path: destination.path), overwriteExisting: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertEqual(try String(contentsOf: destinationFile, encoding: .utf8), "moved")
        XCTAssertNoThrow(try FileManager.default.contentsOfDirectory(atPath: root.localURL?.path ?? tempRoot.path))
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

    private func tagNames(of url: URL) throws -> [String] {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    private func makeItem(id: String, location: Location, isWritable: Bool) -> FileItem {
        FileItem(
            id: id,
            name: "item",
            location: location,
            kind: .file,
            size: nil,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: nil,
            fileExtension: nil,
            isHidden: false,
            isReadable: true,
            isWritable: isWritable
        )
    }

}
