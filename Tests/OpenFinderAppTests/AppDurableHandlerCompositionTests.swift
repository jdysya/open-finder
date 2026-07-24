import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppDurableHandlerCompositionTests: XCTestCase {
    func testApprovedHandlerAndRendererMatrixIsComplete() throws {
        let composition = try AppDurableHandlerComposition(
            taskRegistrations: Self.approvedTaskRegistrations,
            resultHandlers: [PluginResultHandlerRegistry.mediaAnalysis],
            rendererEntries: [.mediaAnalysis]
        )

        XCTAssertEqual(
            composition.registeredTaskKeys,
            Set([
                .init(handlerID: "plugin.execute.v1", payloadVersion: 1),
                .init(handlerID: "transfer.copy.v1", payloadVersion: 1),
                .init(handlerID: "transfer.move.v1", payloadVersion: 1),
            ])
        )
        XCTAssertEqual(composition.registeredResultSchemas, ["mediaAnalysis.v1"])
        XCTAssertEqual(composition.registeredRendererSchemas, ["mediaAnalysis.v1"])
    }

    func testMissingMediaRendererBlocksReadiness() async throws {
        XCTAssertThrowsError(try AppDurableHandlerComposition(
            taskRegistrations: Self.approvedTaskRegistrations,
            resultHandlers: [PluginResultHandlerRegistry.mediaAnalysis],
            rendererEntries: []
        )) { error in
            XCTAssertEqual(
                error as? AppDurableHandlerCompositionError,
                .missingRenderer("mediaAnalysis.v1")
            )
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingMediaRenderer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingPluginRunner()
        let app = AppModel(
            remoteDirectory: RemoteAccountDirectory(
                storageURL: root.appendingPathComponent("accounts.json")
            ),
            configurationStore: JSONConfigStore(
                url: root.appendingPathComponent("config.json")
            ),
            keychainStore: InMemoryKeychainStore(),
            pluginRunnerRouter: PluginRunnerRouter(
                processRunner: runner,
                httpRunner: runner
            ),
            pluginConnectionChecker: StubPluginConnectionChecker.ready,
            pluginRendererEntries: [],
            startAutomatically: false
        )
        let plugin = LoadedPlugin(
            manifest: AppPluginFixture.manifest(
                id: "fixture.missing-renderer",
                execution: .process(runtime: .shell, entry: "run.sh")
            ),
            directory: root
        )

        app.runPlugin(
            plugin,
            action: plugin.manifest.actions[0],
            items: [],
            pane: app.leftPane
        )
        try await AppPluginFixture.waitUntil {
            if case .unavailable = app.durableHandlerReadiness { return true }
            return false
        }

        let records = await app.taskQueue.history()
        let requests = await runner.captured()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    private static var approvedTaskRegistrations: [
        AppDurableHandlerComposition.TaskRegistration
    ] {
        [
            .init(
                handler: inertHandler(.pluginExecute),
                dependencies: [.pluginResolver, .credentialResolver, .pluginExecutionCoordinator]
            ),
            .init(
                handler: inertHandler(.transferCopy),
                dependencies: [.fileSourceRegistry, .transferCoordinator]
            ),
            .init(
                handler: inertHandler(.transferMove),
                dependencies: [.fileSourceRegistry, .transferCoordinator]
            ),
        ]
    }

    private static func inertHandler(_ id: DurableTaskHandlerID) -> TaskHandler {
        TaskHandler(handlerID: id.rawValue, payloadVersion: 1) { _, _ in
            .success(summary: "unused", clipboard: nil)
        }
    }
}
