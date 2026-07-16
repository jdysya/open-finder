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

    func testPersistAssetsCopiesFramesAndReportIntoStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoAnalysisStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let frame = source.appendingPathComponent("frame.jpg")
        let report = source.appendingPathComponent("report.html")
        try Data("frame".utf8).write(to: frame)
        try Data("report".utf8).write(to: report)
        let result = VideoAnalysisResult(
            taskID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            videos: [.init(
                path: "/tmp/demo.mp4",
                name: "demo.mp4",
                summary: .init(totalFrames: 1, faceVisible: 0, explicit: 0, moderate: 0, partial: 0, none: 1),
                frames: [.init(index: 0, timestamp: 1, imagePath: frame.path, faceVisible: false, faceCount: 0, nudityLevel: .none, summary: "frame", tags: [])],
                suggestedTags: [],
                reportPath: report.path
            )]
        )
        let store = VideoAnalysisResultStore(directory: root.appendingPathComponent("store"))

        let persisted = try await store.persistAssets(in: result)

        let persistedVideo = try XCTUnwrap(persisted.videos.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedVideo.frames[0].imagePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(persistedVideo.reportPath)))
        XCTAssertTrue(persistedVideo.frames[0].imagePath.contains("assets/11111111-1111-1111-1111-111111111111"))

        let persistedAgain = try await store.persistAssets(in: persisted)

        XCTAssertEqual(persistedAgain, persisted)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: persistedVideo.frames[0].imagePath)), Data("frame".utf8))
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
