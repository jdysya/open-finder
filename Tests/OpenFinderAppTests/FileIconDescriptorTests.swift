import XCTest
import OpenFinderCore
@testable import OpenFinderApp

@MainActor
final class FileIconDescriptorTests: XCTestCase {
    func testMapsCommonFileExtensionsToDistinctSystemIcons() {
        XCTAssertEqual(FileIconDescriptor.descriptor(for: item(named: "image.png")).systemImageName, "photo.fill")
        XCTAssertEqual(FileIconDescriptor.descriptor(for: item(named: "document.pdf")).systemImageName, "doc.richtext.fill")
        XCTAssertEqual(FileIconDescriptor.descriptor(for: item(named: "archive.zip")).systemImageName, "archivebox.fill")
        XCTAssertEqual(FileIconDescriptor.descriptor(for: item(named: "movie.mp4")).systemImageName, "film.fill")
        XCTAssertEqual(FileIconDescriptor.descriptor(for: item(named: "script.swift")).systemImageName, "curlybraces")
    }

    func testUsesBlueFolderIconForDirectories() {
        let folder = FileItem(
            id: "folder",
            name: "Folder",
            location: .local(path: "/tmp/Folder"),
            kind: .directory,
            size: nil,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: nil,
            fileExtension: nil,
            isHidden: false,
            isReadable: true,
            isWritable: true
        )

        let descriptor = FileIconDescriptor.descriptor(for: folder)

        XCTAssertEqual(descriptor.systemImageName, "folder.fill")
        XCTAssertEqual(descriptor.tintName, "blue")
    }

    private func item(named name: String) -> FileItem {
        FileItem(
            id: name,
            name: name,
            location: .local(path: "/tmp/\(name)"),
            kind: .file,
            size: 1_024,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: nil,
            fileExtension: URL(fileURLWithPath: name).pathExtension.lowercased(),
            isHidden: false,
            isReadable: true,
            isWritable: true
        )
    }
}
