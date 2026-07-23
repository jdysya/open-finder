import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppRuntimeConfigurationTests: XCTestCase {
    func testInitialConfigurationAppliesTaskConcurrencyAndHiddenFileDefaults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppRuntimeConfiguration-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RuntimeConfigurationStore(configuration: .init(
            defaultShowHiddenFiles: true,
            maxConcurrentTasks: 4
        ))
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let app = AppModel(
            remoteDirectory: RemoteAccountDirectory(storageURL: root.appendingPathComponent("accounts.json")),
            configurationStore: store,
            keychainStore: InMemoryKeychainStore(),
            taskQueue: queue,
            startAutomatically: false
        )

        await app.loadInitialState()

        XCTAssertTrue(app.leftPane.showHiddenFiles)
        XCTAssertTrue(app.rightPane.showHiddenFiles)
        let concurrency = await queue.currentMaxConcurrentTasks()
        XCTAssertEqual(concurrency, 4)
    }

    func testChangingConcurrencySettingUpdatesExistingQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLiveConcurrency-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let app = AppModel(
            remoteDirectory: RemoteAccountDirectory(storageURL: root.appendingPathComponent("accounts.json")),
            configurationStore: RuntimeConfigurationStore(configuration: .init()),
            keychainStore: InMemoryKeychainStore(),
            taskQueue: queue,
            startAutomatically: false
        )
        var configuration = app.configuration
        configuration.maxConcurrentTasks = 5

        app.configuration = configuration
        try await AppPluginFixture.waitUntil {
            await queue.currentMaxConcurrentTasks() == 5
        }

        let concurrency = await queue.currentMaxConcurrentTasks()
        XCTAssertEqual(concurrency, 5)
    }
}

private actor RuntimeConfigurationStore: AppConfigurationStore {
    private var configuration: AppConfiguration

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func load() async throws -> AppConfiguration { configuration }
    func save(_ configuration: AppConfiguration) async throws { self.configuration = configuration }
}
