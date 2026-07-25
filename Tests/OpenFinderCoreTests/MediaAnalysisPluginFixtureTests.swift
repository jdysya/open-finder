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

    func testSpectrumInspectorFixtureEmitsDecodableMediaAnalysisDocument() async throws {
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
        let action = try XCTUnwrap(spectrum.manifest.actions.single)
        let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpectrumInspectorFixtureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let result = try await ProcessPluginRunner().run(.init(
            manifest: spectrum.manifest,
            action: action,
            input: .init(
                schemaVersion: 1,
                taskID: taskID,
                actionID: action.id,
                app: .init(name: "OpenFinder", version: "test"),
                context: .init(activePane: "left", currentLocation: .local(path: outputDirectory.path)),
                files: [PluginInputFile(item: FileItem(
                    id: "fixture-tone",
                    name: "tone.wav",
                    location: .local(path: outputDirectory.appendingPathComponent("tone.wav").path),
                    kind: .file,
                    size: 1,
                    modificationDate: nil,
                    creationDate: nil,
                    uti: "public.wav",
                    mimeType: "audio/wav",
                    fileExtension: "wav",
                    isHidden: false,
                    isReadable: true,
                    isWritable: false
                ))],
                config: [:],
                secrets: [:],
                tempDirectory: outputDirectory.path,
                outputDirectory: outputDirectory.path
            ),
            environment: [:],
            pluginDirectory: spectrum.directory,
            workingDirectory: spectrum.directory
        ))

        XCTAssertEqual(result.exitCode, 0)
        let terminal = try XCTUnwrap(result.events.single)
        guard case let .result(status, _, _, artifacts) = terminal else {
            return XCTFail("Expected the fixture to emit one terminal result event.")
        }
        XCTAssertEqual(status, "success")
        let descriptor = try XCTUnwrap(artifacts.single)
        XCTAssertEqual(descriptor.type, MediaAnalysisDocument.schemaIdentifier)
        let body = try XCTUnwrap(descriptor.content)
        let document = try JSONDecoder.openFinder.decode(MediaAnalysisDocument.self, from: Data(body.utf8))

        XCTAssertEqual(document.taskID, taskID)
        XCTAssertFalse(document.items.isEmpty)
        let projection = try await PluginResultHandlerRegistry.standard.handle(.init(
            resultSchemaID: MediaAnalysisDocument.schemaIdentifier,
            pluginID: spectrum.id,
            pluginVersion: spectrum.manifest.version,
            actionID: action.id,
            taskID: taskID,
            events: result.events,
            outputDirectory: outputDirectory
        ))
        XCTAssertEqual(projection.handlerIdentifier, .mediaAnalysis)
        XCTAssertEqual(
            try XCTUnwrap(projection.project(MediaAnalysisDocument.self)).documentID,
            document.documentID
        )
    }

    func testSpectrumInspectorFixtureRejectsEmptyFilesWithSafeTerminalFailure() async throws {
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
        let action = try XCTUnwrap(spectrum.manifest.actions.single)
        let taskID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpectrumInspectorFixtureMalformedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let result = try await ProcessPluginRunner().run(.init(
            manifest: spectrum.manifest,
            action: action,
            input: .init(
                schemaVersion: 1,
                taskID: taskID,
                actionID: action.id,
                app: .init(name: "OpenFinder", version: "test"),
                context: .init(activePane: "left", currentLocation: .local(path: outputDirectory.path)),
                files: [],
                config: [:],
                secrets: [:],
                tempDirectory: outputDirectory.path,
                outputDirectory: outputDirectory.path
            ),
            environment: [:],
            pluginDirectory: spectrum.directory,
            workingDirectory: spectrum.directory
        ))

        XCTAssertEqual(result.exitCode, 0)
        let terminal = try XCTUnwrap(result.events.single)
        guard case let .result(status, message, _, artifacts) = terminal else {
            return XCTFail("Expected the fixture to emit one terminal result event.")
        }
        XCTAssertEqual(status, "failure")
        XCTAssertEqual(message, "Invalid plugin input.")
        XCTAssertTrue(artifacts.isEmpty)
    }
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
