import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppConfigurationAndPluginServiceTests: XCTestCase {
    func testConfigurationServicePersistsLatestRevisionAndRestartsFromIt() async throws {
        let store = ServiceConfigurationStore()
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let service = RuntimeConfigurationService(store: store, taskQueue: queue)
        var first = AppConfiguration(defaultShowHiddenFiles: true, maxConcurrentTasks: 3)
        service.publish(first)
        first.maxConcurrentTasks = 5
        service.publish(first)

        await service.flush()

        let persisted = await store.snapshot()
        let concurrency = await queue.currentMaxConcurrentTasks()
        XCTAssertEqual(persisted, first)
        XCTAssertEqual(concurrency, 5)
        let restarted = RuntimeConfigurationService(store: store, taskQueue: queue)
        let reloaded = try await restarted.load()
        XCTAssertEqual(reloaded, first)
    }

    func testPluginServiceScansValidSiblingAndReportsMalformedManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginService-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("Valid.plugin", isDirectory: true)
        let malformed = root.appendingPathComponent("Malformed\nIGNORE.plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Self.validManifestData.write(to: valid.appendingPathComponent("manifest.json"))
        try Data("#!/bin/sh\n".utf8).write(to: valid.appendingPathComponent("run.sh"))
        try Data("{bad-json".utf8).write(to: malformed.appendingPathComponent("manifest.json"))
        let service = makePluginService()

        let catalog = service.scan(locations: [(root, .development)])

        XCTAssertEqual(catalog.loaded.map(\.id), ["fixture.service-plugin"])
        XCTAssertEqual(catalog.diagnostics.count, 1)
        XCTAssertEqual(catalog.diagnostics.first?.kind, .invalidManifest)
        XCTAssertFalse(catalog.diagnostics.first?.message.contains("\n") == true)
        XCTAssertFalse(catalog.diagnostics.first?.message.contains("fixture-secret") == true)
    }

    func testConfigurationServiceSerializesStaleAndFlakySaves() async {
        let store = AdversarialConfigurationStore()
        let service = RuntimeConfigurationService(
            store: store,
            taskQueue: TaskQueueService(maxConcurrentTasks: 1)
        )
        await store.failNextSave()
        service.publish(.init(maxConcurrentTasks: 3))
        service.publish(.init(defaultShowHiddenFiles: true, maxConcurrentTasks: 6))

        async let firstFlush: Void = service.flush()
        async let repeatedFlush: Void = service.flush()
        _ = await (firstFlush, repeatedFlush)

        let persisted = await store.snapshot()
        let attempts = await store.saveAttempts()
        XCTAssertTrue(persisted.defaultShowHiddenFiles)
        XCTAssertEqual(persisted.maxConcurrentTasks, 6)
        XCTAssertEqual(attempts, 2)
    }

    func testCancelledFlushAndDirtyUpdateDoNotCancelBlockedPersistence() async {
        let store = BlockingConfigurationStore()
        let service = RuntimeConfigurationService(
            store: store,
            taskQueue: TaskQueueService(maxConcurrentTasks: 1)
        )
        await store.blockNextSave()
        service.publish(.init(defaultShowHiddenFiles: true, maxConcurrentTasks: 3))
        await store.waitUntilBlocked()
        let cancelledFlush = Task { await service.flush() }
        cancelledFlush.cancel()
        service.publish(.init(
            defaultShowHiddenFiles: true,
            confirmBeforePermanentDelete: false,
            maxConcurrentTasks: 7
        ))

        await store.releaseBlockedSave()
        await cancelledFlush.value
        await service.flush()

        let persisted = await store.snapshot()
        let attempts = await store.saveAttempts()
        XCTAssertFalse(persisted.confirmBeforePermanentDelete)
        XCTAssertEqual(persisted.maxConcurrentTasks, 7)
        XCTAssertEqual(attempts, 2)
    }

    func testPluginServiceResolvesOnlyDeclaredConfigurationAndChecksConnection() async {
        let checker = CapturingConnectionChecker()
        let service = makePluginService(connectionChecker: checker)
        let manifest = try! JSONDecoder.openFinder.decode(
            PluginManifest.self,
            from: Self.httpManifestData
        )
        let configuration = AppConfiguration(pluginConfigurationValues: [
            manifest.id: [
                "serverURL": "  https://service.example.test  ",
                "undeclared": "ignore-me"
            ]
        ])

        let resolved = service.resolvedConfiguration(
            for: manifest,
            configuration: configuration
        )
        let status = await service.checkConnection(
            LoadedPlugin(manifest: manifest, directory: URL(fileURLWithPath: "/tmp")),
            configuration: configuration
        )

        XCTAssertEqual(resolved.config, ["serverURL": "https://service.example.test"])
        XCTAssertEqual(status.state, .ready)
        let captured = await checker.capturedValues()
        XCTAssertEqual(captured, ["serverURL": "https://service.example.test"])
    }

    func testTempRootScanConnectionSecretRedactionAndRestartProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigurationPluginManual-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginRoot = root.appendingPathComponent("Plugins", isDirectory: true)
        let valid = pluginRoot.appendingPathComponent("HTTP.plugin", isDirectory: true)
        let malformed = pluginRoot.appendingPathComponent("Broken.plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Self.httpManifestData.write(to: valid.appendingPathComponent("manifest.json"))
        try Data("{malformed".utf8).write(to: malformed.appendingPathComponent("manifest.json"))
        let configURL = root.appendingPathComponent("config.json")
        let store = JSONConfigStore(url: configURL)
        let configurationService = RuntimeConfigurationService(
            store: store,
            taskQueue: TaskQueueService(maxConcurrentTasks: 1)
        )
        let checker = CapturingConnectionChecker()
        let pluginService = PluginManagementService(
            configurationService: configurationService,
            keychainStore: InMemoryKeychainStore(),
            localCredentialStore: LocalPluginCredentialStore(),
            connectionChecker: checker
        )
        let configuration = AppConfiguration(pluginConfigurationValues: [
            "fixture.http-service-plugin": [
                "serverURL": "https://service.example.test"
            ]
        ])
        configurationService.publish(configuration)
        await configurationService.flush()
        let catalog = pluginService.scan(locations: [(pluginRoot, .user)])
        let plugin = try XCTUnwrap(catalog.loaded.first)
        let secretResult = await pluginService.setSecret(
            "fixture-manual-secret",
            manifest: plugin.manifest,
            key: "apiToken"
        )
        let connection = await pluginService.checkConnection(
            plugin,
            configuration: configuration
        )
        let restarted = RuntimeConfigurationService(
            store: store,
            taskQueue: TaskQueueService(maxConcurrentTasks: 1)
        )
        let reloaded = try await restarted.load()
        let persistedBytes = try Data(contentsOf: configURL)

        XCTAssertEqual(catalog.loaded.map(\.id), ["fixture.http-service-plugin"])
        XCTAssertEqual(catalog.diagnostics.count, 1)
        XCTAssertEqual(connection.state, .ready)
        XCTAssertEqual(reloaded, configuration)
        XCTAssertTrue(secretResult.succeeded)
        XCTAssertFalse(secretResult.message.contains("fixture-manual-secret"))
        XCTAssertFalse(persistedBytes.contains(Data("fixture-manual-secret".utf8)))
        XCTAssertFalse(String(describing: reloaded).contains("fixture-manual-secret"))
        XCTAssertFalse(connection.guidance.contains("fixture-manual-secret"))
    }

    func testSecretReferenceIsResolvedWithoutPublishingSecretValue() async {
        let keychain = InMemoryKeychainStore()
        let service = makePluginService(keychain: keychain)
        let manifest = try! JSONDecoder.openFinder.decode(
            PluginManifest.self,
            from: Self.validManifestData
        )

        let result = await service.setSecret(
            "fixture-secret",
            manifest: manifest,
            key: "apiToken"
        )
        let references = service.configuredSecretReferences(for: manifest)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(
            references["apiToken"],
            PluginCredentialReference.keychain(pluginID: manifest.id, key: "apiToken")
        )
        XCTAssertFalse(result.message.contains("fixture-secret"))
    }

    private func makePluginService(
        keychain: any KeychainStore = InMemoryKeychainStore(),
        connectionChecker: (any PluginConnectionChecking)? = nil
    ) -> PluginManagementService {
        let configuration = RuntimeConfigurationService(
            store: ServiceConfigurationStore(),
            taskQueue: TaskQueueService(maxConcurrentTasks: 1)
        )
        return PluginManagementService(
            configurationService: configuration,
            keychainStore: keychain,
            localCredentialStore: LocalPluginCredentialStore(),
            connectionChecker: connectionChecker ?? ServiceConnectionChecker()
        )
    }

    private static let validManifestData = Data(
        """
        {
          "schemaVersion": 1,
          "id": "fixture.service-plugin",
          "name": "Service Plugin",
          "version": "1.0.0",
          "runtime": "shell",
          "entry": "run.sh",
          "actions": [],
          "permissions": {
            "readFiles": "none",
            "writeFiles": "none",
            "network": {"required": false, "hosts": []},
            "clipboardWrite": false,
            "clipboardRead": false,
            "keychainSecrets": ["apiToken"],
            "remoteAccounts": false,
            "runExternalCommands": false
          },
          "configuration": []
        }
        """.utf8
    )

    private static let httpManifestData = Data(
        """
        {
          "schemaVersion": 2,
          "id": "fixture.http-service-plugin",
          "name": "HTTP Service Plugin",
          "version": "1.0.0",
          "execution": {
            "type": "http",
            "protocolVersion": 1,
            "endpointConfigurationKey": "serverURL",
            "tokenSecretKey": "apiToken"
          },
          "actions": [],
          "permissions": {
            "readFiles": "none",
            "writeFiles": "none",
            "network": {"required": true, "hosts": ["service.example.test"]},
            "clipboardWrite": false,
            "clipboardRead": false,
            "keychainSecrets": ["apiToken"],
            "remoteAccounts": false,
            "runExternalCommands": false
          },
          "configuration": [
            {"key": "serverURL", "type": "url", "title": "Server", "required": true}
          ]
        }
        """.utf8
    )
}

private actor ServiceConfigurationStore: AppConfigurationStore {
    private var configuration = AppConfiguration()

    func load() async throws -> AppConfiguration { configuration }
    func save(_ configuration: AppConfiguration) async throws { self.configuration = configuration }
    func snapshot() -> AppConfiguration { configuration }
}

private struct ServiceConnectionChecker: PluginConnectionChecking {
    func check(
        manifest: PluginManifest,
        values: [String: String],
        secretReferences: [String: String]
    ) async -> PluginConnectionStatus {
        PluginConnectionStatus(state: .ready, guidance: "Ready")
    }
}

private actor CapturingConnectionChecker: PluginConnectionChecking {
    private var values: [String: String] = [:]

    func check(
        manifest: PluginManifest,
        values: [String: String],
        secretReferences: [String: String]
    ) async -> PluginConnectionStatus {
        self.values = values
        return PluginConnectionStatus(state: .ready, guidance: "Ready")
    }

    func capturedValues() -> [String: String] { values }
}

private actor AdversarialConfigurationStore: AppConfigurationStore {
    private var configuration = AppConfiguration()
    private var shouldFail = false
    private var attempts = 0

    func load() async throws -> AppConfiguration { configuration }

    func save(_ configuration: AppConfiguration) async throws {
        attempts += 1
        if shouldFail {
            shouldFail = false
            throw OpenFinderError.operationFailed("fixture flaky save")
        }
        self.configuration = configuration
    }

    func failNextSave() {
        shouldFail = true
    }

    func snapshot() -> AppConfiguration { configuration }
    func saveAttempts() -> Int { attempts }
}

private actor BlockingConfigurationStore: AppConfigurationStore {
    private var configuration = AppConfiguration()
    private var shouldBlock = false
    private var isBlocked = false
    private var attempts = 0
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func load() async throws -> AppConfiguration { configuration }

    func save(_ configuration: AppConfiguration) async throws {
        attempts += 1
        if shouldBlock {
            shouldBlock = false
            isBlocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            isBlocked = false
        }
        self.configuration = configuration
    }

    func blockNextSave() {
        shouldBlock = true
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseBlockedSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func snapshot() -> AppConfiguration { configuration }
    func saveAttempts() -> Int { attempts }
}
