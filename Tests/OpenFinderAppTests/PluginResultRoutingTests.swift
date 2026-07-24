import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

final class PluginResultRoutingTests: XCTestCase {
    func testTwoPluginIDsShareMediaAnalysisHandlerAndRenderer() async throws {
        // Given
        let taskID = UUID()
        let document = MediaAnalysisDocument(
            documentID: UUID(),
            taskID: taskID,
            items: [],
            suggestedTags: [],
            actions: MediaAnalysisAction.standard,
            managedTagLedger: .init(mediaEntries: []),
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        let content = String(decoding: try JSONEncoder.openFinder.encode(document), as: UTF8.self)
        let events: [PluginOutputEvent] = [
            .result(
                status: "success",
                message: "done",
                clipboard: nil,
                artifacts: [.init(type: MediaAnalysisDocument.schemaIdentifier, content: content)]
            )
        ]
        let registry = PluginResultHandlerRegistry.standard
        let catalog = PluginRendererCatalog.standard

        // When
        let first = try await registry.handle(.init(
            resultSchemaID: MediaAnalysisDocument.schemaIdentifier,
            pluginID: "fixture.process.media",
            pluginVersion: "1.2.3",
            actionID: "inspect",
            taskID: taskID,
            events: events,
            outputDirectory: FileManager.default.temporaryDirectory
        ))
        let second = try await registry.handle(.init(
            resultSchemaID: MediaAnalysisDocument.schemaIdentifier,
            pluginID: "fixture.http.alternate",
            pluginVersion: "9.8.7",
            actionID: "classify",
            taskID: taskID,
            events: events,
            outputDirectory: FileManager.default.temporaryDirectory
        ))

        // Then
        XCTAssertEqual(first.handlerIdentifier, PluginResultHandlerIdentifier.mediaAnalysis)
        XCTAssertEqual(second.handlerIdentifier, PluginResultHandlerIdentifier.mediaAnalysis)
        XCTAssertEqual(first.project(MediaAnalysisDocument.self), document)
        XCTAssertEqual(second.project(MediaAnalysisDocument.self), document)
        XCTAssertEqual(catalog.renderer(for: first).identifier, .mediaAnalysis)
        XCTAssertEqual(catalog.renderer(for: second).identifier, .mediaAnalysis)
    }

    func testLegacyVideoSchemaIsNotDecodedAsMediaAnalysis() async throws {
        // Given
        let taskID = UUID()
        let legacy = PluginResultHandlingContext(
            resultSchemaID: "videoAnalysisResult",
            pluginID: "dev.openfinder.plugins.video-analyzer",
            pluginVersion: "0.1.0",
            actionID: "analyze-video",
            taskID: taskID,
            events: [.result(
                status: "success",
                message: "legacy",
                clipboard: nil,
                artifacts: [.init(type: "videoAnalysisResult", content: #"{"schemaVersion":1}"#)]
            )],
            outputDirectory: FileManager.default.temporaryDirectory
        )
        let registry = PluginResultHandlerRegistry.standard

        // When
        let projection = try await registry.handle(legacy)

        // Then
        XCTAssertEqual(projection.handlerIdentifier, PluginResultHandlerIdentifier.unknown)
        XCTAssertNil(projection.project(MediaAnalysisDocument.self))
        XCTAssertEqual(PluginRendererCatalog.standard.renderer(for: projection).identifier, .unknown)
        await XCTAssertThrowsErrorAsync {
            _ = try await PluginResultHandlerRegistry.mediaAnalysis.handle(legacy)
        }
    }

    func testCoordinatorPreservesExactSnapshotsAcrossProcessAndHTTP() async throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginCoordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let processRunner = MediaDocumentPluginRunner()
        let httpRunner = MediaDocumentPluginRunner()
        let keychain = InMemoryKeychainStore()
        try keychain.setSecret("redacted-fixture-value", for: "fixture.http.token")
        let credentials = PluginCredentialResolver(
            keychainStore: keychain,
            localStore: LocalPluginCredentialStore()
        )
        let coordinator = PluginExecutionCoordinator(
            runner: PluginRunnerRouter(processRunner: processRunner, httpRunner: httpRunner),
            connectionChecker: ExactPluginConnectionChecker(),
            credentialResolver: credentials,
            temporaryDirectory: root
        )
        let process = routingPlugin(
            id: "fixture.process.media",
            version: "1.2.3",
            actionID: "inspect",
            execution: .process(runtime: .shell, entry: "fixture.sh")
        )
        let http = routingPlugin(
            id: "fixture.http.alternate",
            version: "9.8.7",
            actionID: "classify",
            execution: .http(
                protocolVersion: 1,
                endpointConfigurationKey: "serverURL",
                tokenSecretKey: "serverToken"
            )
        )
        let processTaskID = UUID()
        let httpTaskID = UUID()

        // When
        let processOutcome = try await coordinator.execute(executionRequest(
            plugin: process,
            taskID: processTaskID,
            configuration: ["quality": "exact-snapshot"]
        ))
        let httpOutcome = try await coordinator.execute(executionRequest(
            plugin: http,
            taskID: httpTaskID,
            configuration: ["serverURL": "http://127.0.0.1:8765", "quality": "exact-snapshot"],
            secretReferences: ["serverToken": "fixture.http.token"]
        ))
        let processRequest = await processRunner.captured().single
        let httpRequest = await httpRunner.captured().single

        // Then
        XCTAssertEqual(processOutcome.projection.handlerIdentifier, .mediaAnalysis)
        XCTAssertEqual(httpOutcome.projection.handlerIdentifier, .mediaAnalysis)
        XCTAssertEqual(processRequest?.manifest.id, process.id)
        XCTAssertEqual(processRequest?.manifest.version, "1.2.3")
        XCTAssertEqual(processRequest?.action.id, "inspect")
        XCTAssertEqual(processRequest?.input.config["quality"], "exact-snapshot")
        XCTAssertEqual(httpRequest?.manifest.id, http.id)
        XCTAssertEqual(httpRequest?.manifest.version, "9.8.7")
        XCTAssertEqual(httpRequest?.action.id, "classify")
        XCTAssertEqual(httpRequest?.input.secrets["serverToken"]?.env, "fixture.http.token")
        XCTAssertTrue(httpRequest?.environment.isEmpty == true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "OpenFinderHTTPTasks/\(httpTaskID.uuidString)"
            ).path
        ))
    }

    private func routingPlugin(
        id: String,
        version: String,
        actionID: String,
        execution: PluginExecution
    ) -> LoadedPlugin {
        let isHTTP: Bool
        switch execution {
        case .process:
            isHTTP = false
        case .http:
            isHTTP = true
        }
        return LoadedPlugin(
            manifest: .init(
                schemaVersion: isHTTP ? 2 : 1,
                id: id,
                name: id,
                version: version,
                description: nil,
                author: nil,
                execution: execution,
                actions: [.init(
                    id: actionID,
                    title: actionID,
                    category: nil,
                    selection: .init(),
                    match: nil,
                    output: .init(
                        resultType: MediaAnalysisDocument.schemaIdentifier,
                        canCopyToClipboard: false
                    )
                )],
                permissions: .init(
                    readFiles: "selected",
                    writeFiles: "taskOutput",
                    network: .init(required: isHTTP, hosts: isHTTP ? ["127.0.0.1"] : []),
                    clipboardWrite: false,
                    clipboardRead: false,
                    keychainSecrets: isHTTP ? ["serverToken"] : [],
                    remoteAccounts: false,
                    runExternalCommands: !isHTTP
                ),
                configuration: isHTTP
                    ? [
                        .init(key: "serverURL", type: "url", title: "Server"),
                        .init(key: "quality", type: "string", title: "Quality")
                    ]
                    : [.init(key: "quality", type: "string", title: "Quality")]
            ),
            directory: FileManager.default.temporaryDirectory
        )
    }

    private func executionRequest(
        plugin: LoadedPlugin,
        taskID: UUID,
        configuration: [String: String],
        secretReferences: [String: String] = [:]
    ) -> PluginExecutionRequest {
        .init(
            plugin: plugin,
            pluginVersion: plugin.manifest.version,
            action: plugin.manifest.actions[0],
            taskID: taskID,
            app: .init(name: "OpenFinder", version: "test"),
            context: .init(activePane: "left", currentLocation: .local(path: "/tmp")),
            files: [],
            configurationValues: configuration,
            secretReferences: secretReferences
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected operation to throw", file: file, line: line)
    } catch {}
}
