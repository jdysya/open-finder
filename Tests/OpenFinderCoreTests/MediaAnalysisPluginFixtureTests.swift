import Foundation
import XCTest
@testable import OpenFinderCore

final class MediaAnalysisPluginFixtureTests: XCTestCase {
    func testTwoDistinctPluginManifestsDeclareGenericMediaAnalysisResult() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let examplePlugins = try PluginRegistry().scan(
            directory: sourceRoot.appendingPathComponent("ExamplePlugins")
        )
        let video = try XCTUnwrap(
            examplePlugins.first { $0.id == "dev.openfinder.plugins.video-analyzer" }
        )

        let fixtureRoot = try XCTUnwrap(
            Bundle.module.resourceURL?
                .appendingPathComponent("Fixtures", isDirectory: true)
                .appendingPathComponent("MediaAnalysisPlugins", isDirectory: true)
        )
        let spectrum = try XCTUnwrap(
            try PluginRegistry().scan(directory: fixtureRoot).first {
                $0.id == "dev.openfinder.fixtures.spectrum-inspector"
            }
        )

        XCTAssertNotEqual(video.id, spectrum.id)
        XCTAssertEqual(
            video.manifest.actions.single?.output?.resultType,
            MediaAnalysisDocument.schemaIdentifier
        )
        XCTAssertEqual(
            spectrum.manifest.actions.single?.output?.resultType,
            MediaAnalysisDocument.schemaIdentifier
        )
    }
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
