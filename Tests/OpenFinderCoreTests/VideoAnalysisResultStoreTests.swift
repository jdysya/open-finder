import Foundation
import XCTest
@testable import OpenFinderCore

final class VideoAnalysisResultStoreTests: XCTestCase {
    func testSaveAndLoadRoundTripsMatchingFingerprint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoAnalysisStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VideoAnalysisResultStore(directory: root)
        let fingerprint = Self.fingerprint(size: 100)
        let stored = StoredVideoAnalysis(fingerprint: fingerprint, result: Self.result, analyzedAt: Date(timeIntervalSince1970: 1_700_000_000))

        try await store.save(stored)
        let loaded = try await store.load(for: fingerprint)

        XCTAssertEqual(loaded, stored)
    }

    func testLoadRejectsStaleFingerprintForSamePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoAnalysisStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VideoAnalysisResultStore(directory: root)
        let current = Self.fingerprint(size: 100)
        try await store.save(.init(fingerprint: current, result: Self.result, analyzedAt: Date()))

        let stale = try await store.load(for: Self.fingerprint(size: 101))

        XCTAssertNil(stale)
    }

    func testLoadReportsCorruptedStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoAnalysisStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("index.json"))
        let store = VideoAnalysisResultStore(directory: root)

        do {
            _ = try await store.load(for: Self.fingerprint(size: 100))
            XCTFail("Expected corrupted store error")
        } catch {
            XCTAssertEqual(error as? VideoAnalysisStoreError, .corruptedStore)
        }
    }

    private static func fingerprint(size: Int64) -> VideoFileFingerprint {
        .init(
            canonicalPath: "/tmp/demo.mp4",
            size: size,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            analyzerVersion: "1.0.0"
        )
    }

    private static let result = VideoAnalysisResult(
        taskID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        videos: []
    )
}
