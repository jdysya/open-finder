import XCTest
@testable import OpenFinderCore

final class VideoAnalysisPresentationTests: XCTestCase {
    func testFacetsIncludeFrameStateAndModelTagsWithCounts() {
        let facets = VideoAnalysisPresentation.facets(for: Self.video)

        XCTAssertEqual(facets.first(where: { $0.label == "露脸" })?.frameCount, 1)
        XCTAssertEqual(facets.first(where: { $0.label == "不露脸" })?.frameCount, 1)
        XCTAssertEqual(facets.first(where: { $0.label == "卧室" })?.frameCount, 2)
        XCTAssertEqual(facets.first(where: { $0.label == "泳装" })?.frameCount, 1)
    }

    func testFilteringRequiresEverySelectedLabel() {
        let filtered = VideoAnalysisPresentation.frames(in: Self.video, matching: ["露脸", "卧室"])

        XCTAssertEqual(filtered.map(\.index), [0])
        XCTAssertTrue(VideoAnalysisPresentation.frames(in: Self.video, matching: ["不存在"]).isEmpty)
    }

    func testFinderSuggestionsIncludeOnlyExplicitlySelectedNames() {
        let selected = VideoAnalysisPresentation.finderTagSuggestions(
            in: Self.video,
            selectedNames: ["泳装", "不存在"]
        )

        XCTAssertEqual(selected.map(\.name), ["泳装"])
    }

    private static let scene = VideoAnalysisTagSuggestion(
        name: "卧室", category: "scene", confidence: 0.9, frameRatio: 1,
        source: "joytag", modelVersion: "legacy"
    )
    private static let adult = VideoAnalysisTagSuggestion(
        name: "泳装", category: "adult", confidence: 0.8, frameRatio: 0.5,
        source: "joytag", modelVersion: "legacy"
    )
    private static let video = AnalyzedVideo(
        path: "/tmp/demo.mp4",
        name: "demo.mp4",
        summary: .init(totalFrames: 2, faceVisible: 1, explicit: 0, moderate: 0, partial: 1, none: 1),
        frames: [
            .init(index: 0, timestamp: 1, imagePath: "/tmp/0.jpg", faceVisible: true, faceCount: 1, nudityLevel: .partial, summary: "first", tags: [scene, adult]),
            .init(index: 1, timestamp: 2, imagePath: "/tmp/1.jpg", faceVisible: false, faceCount: 0, nudityLevel: .none, summary: "second", tags: [scene]),
        ],
        suggestedTags: [scene, adult],
        reportPath: nil
    )
}
