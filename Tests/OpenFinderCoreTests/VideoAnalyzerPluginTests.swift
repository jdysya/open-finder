import Foundation
import XCTest
@testable import OpenFinderCore

final class VideoAnalyzerPluginTests: XCTestCase {
    func testManifestMatchesVideoFilesAndRejectsTextFiles() throws {
        let manifestURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ExamplePlugins/video-analyzer.plugin/manifest.json")
        let manifest = try JSONDecoder.openFinder.decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
        let action = try XCTUnwrap(manifest.actions.single)

        XCTAssertEqual(manifest.id, "dev.openfinder.plugins.video-analyzer")
        XCTAssertTrue(PluginMatcher.action(action, matches: [Self.item(name: "demo.mp4", extension: "mp4", mimeType: "video/mp4")]))
        XCTAssertTrue(PluginMatcher.action(action, matches: [Self.item(name: "demo.mkv", extension: "mkv", mimeType: "video/x-matroska")]))
        XCTAssertFalse(PluginMatcher.action(action, matches: [Self.item(name: "notes.txt", extension: "txt", mimeType: "text/plain")]))
    }

    private static func item(name: String, extension fileExtension: String, mimeType: String) -> FileItem {
        .init(
            id: "local:/tmp/\(name)",
            name: name,
            location: .local(path: "/tmp/\(name)"),
            kind: .file,
            size: 1,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: mimeType,
            fileExtension: fileExtension,
            isHidden: false,
            isReadable: true,
            isWritable: true
        )
    }
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
