import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import OpenFinderCore

final class ConfinedArtifactReaderTests: XCTestCase {
    private let mebibyte = 1_048_576

    func testReadsMatchingRegularFile() throws {
        try withRoot { root in
            let data = Data("hello".utf8)
            _ = try write(data, relativePath: "nested/result.json", root: root)
            let reader = try ConfinedArtifactReader(root: root)

            XCTAssertEqual(try reader.read(metadata(relativePath: "nested/result.json", data: data)), data)
        }
    }

    func testRejectsLexicallyUnsafePaths() throws {
        try withRoot { root in
            let reader = try ConfinedArtifactReader(root: root)
            let paths = ["", "/absolute", "./dot", "nested/./dot", "nested//empty", "../escape", "a/../escape", "a\\b", "C:/escape", "C:\\escape", "nul\0x"]

            for path in paths {
                XCTAssertThrowsError(try reader.validate(relativePath: path)) { error in
                    XCTAssertEqual(error as? ConfinedArtifactError, .invalidRelativePath)
                }
            }
        }
    }

    func testRejectsMissingDirectoryFifoAndSymlinks() throws {
        try withRoot { root in
            let reader = try ConfinedArtifactReader(root: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: true)
            let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: outside) }
            try Data("outside".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("final-link"), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("middle"), withDestinationURL: root)
            let fifo = root.appendingPathComponent("pipe")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

            for path in ["missing", "directory", "pipe", "final-link", "middle/file"] {
                XCTAssertThrowsError(try reader.validate(relativePath: path), "Expected rejection for \(path)")
            }
        }
    }

    func testRejectsReplacedRoot() throws {
        let parent = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reader = try ConfinedArtifactReader(root: root)
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("old-root"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: root.appendingPathComponent("result.json"))

        XCTAssertThrowsError(try reader.validate(relativePath: "result.json")) { error in
            XCTAssertEqual(error as? ConfinedArtifactError, .rootReplaced)
        }
    }

    func testRejectsOversizeSizeAndHashMismatch() throws {
        try withRoot { root in
            let oversize = Data(repeating: 1, count: 50 * mebibyte + 1)
            _ = try write(oversize, relativePath: "oversize.json", root: root)
            let reader = try ConfinedArtifactReader(root: root)
            XCTAssertThrowsError(try reader.read(metadata(relativePath: "oversize.json", data: oversize))) { error in
                XCTAssertEqual(error as? ConfinedArtifactError, .tooLarge)
            }

            let data = Data("hello".utf8)
            _ = try write(data, relativePath: "result.json", root: root)
            let valid = metadata(relativePath: "result.json", data: data)
            let wrongSize = PluginFileArtifact(relativePath: valid.relativePath, mediaType: valid.mediaType, byteCount: 6, sha256: valid.sha256)
            let wrongHash = PluginFileArtifact(relativePath: valid.relativePath, mediaType: valid.mediaType, byteCount: 5, sha256: String(repeating: "0", count: 64))
            XCTAssertThrowsError(try reader.read(wrongSize)) { XCTAssertEqual($0 as? ConfinedArtifactError, .sizeMismatch) }
            XCTAssertThrowsError(try reader.read(wrongHash)) { XCTAssertEqual($0 as? ConfinedArtifactError, .hashMismatch) }
        }
    }

    func testReplacementAfterReaderCreationCannotEscapeRoot() throws {
        try withRoot { root in
            let original = Data("original".utf8)
            let url = try write(original, relativePath: "result.json", root: root)
            let reader = try ConfinedArtifactReader(root: root)
            let expected = metadata(relativePath: "result.json", data: original)
            try FileManager.default.removeItem(at: url)
            try Data("replaced".utf8).write(to: url)

            XCTAssertThrowsError(try reader.read(expected))
        }
    }

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ConfinedArtifactReaderTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ data: Data, relativePath: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func metadata(relativePath: String, data: Data) -> PluginFileArtifact {
        PluginFileArtifact(
            relativePath: relativePath,
            mediaType: "application/json",
            byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }
}
