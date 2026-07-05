import Foundation
import XCTest
@testable import OpenFinderCore

final class DirectorySizeTests: XCTestCase {
    func testCalculatesRecursiveLocalDirectorySizeOffTheListingPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderDirectorySize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 700).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 1_300).write(to: nested.appendingPathComponent("b.bin"))

        let provider = LocalFileProvider()

        let size = try await provider.directorySize(at: .local(path: root.path))

        XCTAssertEqual(size, 2_000)
    }
}
