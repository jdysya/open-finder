import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppLocalPluginSecretTests: XCTestCase {
    func testVideoAnalyzerSaveAndClearUseSecuredLocalConfigWithoutKeychainWrites() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config.json")
        let keychain = RecordingPluginKeychainStore()
        let app = makeApp(root: root, keychain: keychain)
        let plugin = LoadedPlugin(manifest: Self.videoAnalyzerManifest, directory: root)
        app.loadedPlugins = [plugin]

        let saved = await app.setPluginSecret(
            "fixture-local-value", pluginID: plugin.id, key: "serverToken"
        )
        XCTAssertTrue(saved)

        XCTAssertEqual(app.configuration.localPluginSecrets[plugin.id]?["serverToken"], "fixture-local-value")
        XCTAssertNil(app.configuration.pluginConfigurationValues[plugin.id]?["serverToken"])
        XCTAssertEqual(keychain.setKeys, [])
        XCTAssertTrue(app.statusMessage.contains("secured local config"))
        await app.flushConfigurationSaves()
        let persisted = try await JSONConfigStore(url: configURL).load()
        XCTAssertEqual(persisted.localPluginSecrets[plugin.id]?["serverToken"], "fixture-local-value")

        let cleared = await app.setPluginSecret("", pluginID: plugin.id, key: "serverToken")
        XCTAssertTrue(cleared)

        XCTAssertNil(app.configuration.localPluginSecrets[plugin.id])
        XCTAssertEqual(keychain.deletedKeys, [])
        XCTAssertTrue(app.statusMessage.contains("secured local config"))
        await app.flushConfigurationSaves()
        let persistedAfterClear = try await JSONConfigStore(url: configURL).load()
        XCTAssertNil(persistedAfterClear.localPluginSecrets[plugin.id])
        XCTAssertTrue(persistedAfterClear.videoAnalyzerLegacyServerTokenCleared)
    }

    func testFailedLocalSaveRestoresMemoryResolverAndPersistedState() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ControllableConfigurationStore()
        let keychain = RecordingPluginKeychainStore()
        let app = makeApp(root: root, keychain: keychain, configurationStore: store)
        let plugin = LoadedPlugin(manifest: Self.videoAnalyzerManifest, directory: root)
        app.loadedPlugins = [plugin]
        await store.failNextSave()

        let saved = await app.setPluginSecret(
            "fixture-rejected-value", pluginID: plugin.id, key: "serverToken"
        )

        XCTAssertFalse(saved)
        XCTAssertNil(app.configuration.localPluginSecrets[plugin.id])
        XCTAssertNil(app.configuredPluginSecretReferences(for: plugin.manifest)["serverToken"])
        XCTAssertFalse(app.statusMessage.contains("fixture-rejected-value"))
        XCTAssertTrue(app.statusMessage.contains("Could not save plugin secret serverToken"))
        let persisted = await store.snapshot()
        XCTAssertNil(persisted.localPluginSecrets[plugin.id])
        XCTAssertFalse(persisted.videoAnalyzerLegacyServerTokenCleared)
    }

    func testFailedLocalClearRestoresMemoryResolverAndPersistedState() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ControllableConfigurationStore()
        let keychain = RecordingPluginKeychainStore()
        let app = makeApp(root: root, keychain: keychain, configurationStore: store)
        let plugin = LoadedPlugin(manifest: Self.videoAnalyzerManifest, directory: root)
        app.loadedPlugins = [plugin]
        let initialSave = await app.setPluginSecret(
            "fixture-retained-value", pluginID: plugin.id, key: "serverToken"
        )
        XCTAssertTrue(initialSave)
        await store.failNextSave()

        let cleared = await app.setPluginSecret("", pluginID: plugin.id, key: "serverToken")

        XCTAssertFalse(cleared)
        XCTAssertEqual(
            app.configuration.localPluginSecrets[plugin.id]?["serverToken"],
            "fixture-retained-value"
        )
        XCTAssertNotNil(app.configuredPluginSecretReferences(for: plugin.manifest)["serverToken"])
        XCTAssertFalse(app.statusMessage.contains("fixture-retained-value"))
        XCTAssertTrue(app.statusMessage.contains("Could not clear plugin secret serverToken"))
        let persisted = await store.snapshot()
        XCTAssertEqual(
            persisted.localPluginSecrets[plugin.id]?["serverToken"],
            "fixture-retained-value"
        )
        XCTAssertFalse(persisted.videoAnalyzerLegacyServerTokenCleared)
    }

    func testFailedLocalSaveAndClearPersistGenericEditMadeDuringSuspendedFlush() async throws {
        try await assertFailedLocalMutationPersistsConcurrentGenericEdit(
            initialSecret: nil,
            attemptedSecret: "fixture-rejected-value",
            scenario: "save"
        )
        try await assertFailedLocalMutationPersistsConcurrentGenericEdit(
            initialSecret: "fixture-retained-value",
            attemptedSecret: "",
            scenario: "clear"
        )
    }

    func testLegacyVideoAnalyzerKeychainValueMigratesAfterLocalSaveAndIsNotDeleted() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = RecordingPluginKeychainStore()
        let legacyReference = PluginCredentialReference.keychain(
            pluginID: Self.pluginID, key: "serverToken"
        )
        try keychain.setSecret("fixture-legacy-value", for: legacyReference)
        keychain.resetRecordedMutations()
        let app = makeApp(root: root, keychain: keychain)
        let plugin = LoadedPlugin(manifest: Self.videoAnalyzerManifest, directory: root)
        app.loadedPlugins = [plugin]

        await app.migrateLegacyLocalPluginSecrets(in: [plugin])

        XCTAssertEqual(app.configuration.localPluginSecrets[Self.pluginID]?["serverToken"], "fixture-legacy-value")
        XCTAssertEqual(try keychain.secret(for: legacyReference), "fixture-legacy-value")
        XCTAssertEqual(keychain.deletedKeys, [])
        let references = app.configuredPluginSecretReferences(for: Self.videoAnalyzerManifest)
        XCTAssertEqual(
            references["serverToken"],
            PluginCredentialReference.localConfiguration(pluginID: Self.pluginID, key: "serverToken")
        )
    }

    func testLegacyKeychainFallbackSurvivesFailedLocalMigration() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blockingFile)
        let keychain = RecordingPluginKeychainStore()
        let legacyReference = PluginCredentialReference.keychain(
            pluginID: Self.pluginID, key: "serverToken"
        )
        try keychain.setSecret("fixture-legacy-value", for: legacyReference)
        keychain.resetRecordedMutations()
        let app = AppModel(
            remoteDirectory: RemoteAccountDirectory(storageURL: root.appendingPathComponent("accounts.json")),
            configurationStore: JSONConfigStore(url: blockingFile.appendingPathComponent("config.json")),
            keychainStore: keychain,
            startAutomatically: false
        )
        let plugin = LoadedPlugin(manifest: Self.videoAnalyzerManifest, directory: root)

        await app.migrateLegacyLocalPluginSecrets(in: [plugin])

        XCTAssertEqual(app.configuration.localPluginSecrets, [:])
        XCTAssertEqual(
            app.configuredPluginSecretReferences(for: Self.videoAnalyzerManifest)["serverToken"],
            legacyReference
        )
        XCTAssertEqual(keychain.deletedKeys, [])
    }

    func testClearAfterLegacyMigrationSurvivesRestartAndExplicitSaveReenablesLocalSecret() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config.json")
        let keychain = RecordingPluginKeychainStore()
        let legacyReference = PluginCredentialReference.keychain(
            pluginID: Self.pluginID, key: "serverToken"
        )
        try keychain.setSecret("fixture-legacy-value", for: legacyReference)
        keychain.resetRecordedMutations()
        let plugin = LoadedPlugin(manifest: Self.videoAnalyzerManifest, directory: root)
        let app = makeApp(root: root, keychain: keychain)
        app.loadedPlugins = [plugin]
        await app.migrateLegacyLocalPluginSecrets(in: [plugin])

        let clearSucceeded = await app.setPluginSecret("", for: plugin.manifest, key: "serverToken")
        XCTAssertTrue(clearSucceeded)

        XCTAssertNil(app.configuredPluginSecretReferences(for: plugin.manifest)["serverToken"])
        XCTAssertEqual(try keychain.secret(for: legacyReference), "fixture-legacy-value")
        let cleared = try await JSONConfigStore(url: configURL).load()
        XCTAssertTrue(cleared.videoAnalyzerLegacyServerTokenCleared)
        XCTAssertNil(cleared.localPluginSecrets[Self.pluginID])

        let restarted = makeApp(root: root, keychain: keychain)
        restarted.configuration = cleared
        restarted.loadedPlugins = [plugin]
        await restarted.flushConfigurationSaves()
        await restarted.migrateLegacyLocalPluginSecrets(in: [plugin])

        XCTAssertNil(restarted.configuration.localPluginSecrets[Self.pluginID])
        XCTAssertNil(restarted.configuredPluginSecretReferences(for: plugin.manifest)["serverToken"])
        XCTAssertTrue(restarted.configuration.videoAnalyzerLegacyServerTokenCleared)
        XCTAssertEqual(try keychain.secret(for: legacyReference), "fixture-legacy-value")

        let saveSucceeded = await restarted.setPluginSecret(
            "fixture-new-local-value", for: plugin.manifest, key: "serverToken"
        )
        XCTAssertTrue(saveSucceeded)
        XCTAssertFalse(restarted.configuration.videoAnalyzerLegacyServerTokenCleared)
        XCTAssertNotNil(restarted.configuredPluginSecretReferences(for: plugin.manifest)["serverToken"])
        XCTAssertEqual(try keychain.secret(for: legacyReference), "fixture-legacy-value")
        let savedAgain = try await JSONConfigStore(url: configURL).load()
        XCTAssertEqual(
            savedAgain.localPluginSecrets[Self.pluginID]?["serverToken"],
            "fixture-new-local-value"
        )
        XCTAssertFalse(savedAgain.videoAnalyzerLegacyServerTokenCleared)
    }

    func testMigrationMergesGenericConfigurationEditedWhileSaveIsSuspended() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ControllableConfigurationStore()
        let keychain = RecordingPluginKeychainStore()
        let legacyReference = PluginCredentialReference.keychain(
            pluginID: Self.pluginID, key: "serverToken"
        )
        try keychain.setSecret("fixture-legacy-value", for: legacyReference)
        let app = makeApp(root: root, keychain: keychain, configurationStore: store)
        let plugin = LoadedPlugin(manifest: Self.videoAnalyzerManifest, directory: root)
        app.loadedPlugins = [plugin]
        await store.suspendNextSave()
        let migration = Task { await app.migrateLegacyLocalPluginSecrets(in: [plugin]) }
        await store.waitUntilSaveIsSuspended()

        app.setPluginConfigValue("concurrent-value", pluginID: "fixture.concurrent", key: "setting")
        await store.resumeSuspendedSave()
        await migration.value

        XCTAssertEqual(
            app.configuration.pluginConfigurationValues["fixture.concurrent"]?["setting"],
            "concurrent-value"
        )
        let persisted = await store.snapshot()
        XCTAssertEqual(
            persisted.pluginConfigurationValues["fixture.concurrent"]?["setting"],
            "concurrent-value"
        )
        XCTAssertEqual(
            persisted.localPluginSecrets[Self.pluginID]?["serverToken"],
            "fixture-legacy-value"
        )
    }

    func testLegacyPluginAndRemoteAccountStillWriteKeychain() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = RecordingPluginKeychainStore()
        let app = makeApp(root: root, keychain: keychain)
        let legacyManifest = Self.legacyManifest
        app.loadedPlugins = [LoadedPlugin(manifest: legacyManifest, directory: root)]

        let keychainSaveSucceeded = await app.setPluginSecret(
            "fixture-api-value", pluginID: legacyManifest.id, key: "apiToken"
        )
        XCTAssertTrue(keychainSaveSucceeded)
        app.addRemoteAccount(
            connectorID: .webDAV,
            name: "Fixture WebDAV",
            endpoint: "https://files.example.test/dav/",
            username: "user",
            password: "fixture-password",
            allowInsecureHTTP: false
        )

        XCTAssertTrue(keychain.setKeys.contains(
            PluginCredentialReference.keychain(pluginID: legacyManifest.id, key: "apiToken")
        ))
        XCTAssertTrue(keychain.setKeys.contains { $0.hasPrefix("remote.") })
        XCTAssertEqual(app.configuration.localPluginSecrets, [:])
    }

    private func makeApp(
        root: URL,
        keychain: RecordingPluginKeychainStore,
        configurationStore: (any AppConfigurationStore)? = nil
    ) -> AppModel {
        let store: any AppConfigurationStore
        if let configurationStore {
            store = configurationStore
        } else {
            store = JSONConfigStore(url: root.appendingPathComponent("config.json"))
        }
        return AppModel(
            remoteDirectory: RemoteAccountDirectory(storageURL: root.appendingPathComponent("accounts.json")),
            configurationStore: store,
            keychainStore: keychain,
            startAutomatically: false
        )
    }

    private func assertFailedLocalMutationPersistsConcurrentGenericEdit(
        initialSecret: String?,
        attemptedSecret: String,
        scenario: String
    ) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ControllableConfigurationStore()
        let keychain = RecordingPluginKeychainStore()
        let app = makeApp(root: root, keychain: keychain, configurationStore: store)
        let plugin = LoadedPlugin(manifest: Self.videoAnalyzerManifest, directory: root)
        app.loadedPlugins = [plugin]
        if let initialSecret {
            let saved = await app.setPluginSecret(
                initialSecret,
                for: plugin.manifest,
                key: "serverToken"
            )
            XCTAssertTrue(saved, scenario)
        }

        await store.suspendNextSave()
        app.setPluginConfigValue("prior-value", pluginID: "fixture.prior", key: scenario)
        await store.waitUntilSaveIsSuspended()
        let mutation = Task {
            await app.setPluginSecret(attemptedSecret, for: plugin.manifest, key: "serverToken")
        }
        try await AppPluginFixture.waitUntil { app.configurationPersistenceIsDeferred }
        app.setPluginConfigValue("concurrent-value", pluginID: "fixture.concurrent", key: scenario)
        await store.failNextSave()
        await store.resumeSuspendedSave()

        let mutationSucceeded = await mutation.value
        XCTAssertFalse(mutationSucceeded, scenario)
        await app.flushConfigurationSaves()

        XCTAssertEqual(
            app.configuration.localPluginSecrets[Self.pluginID]?["serverToken"],
            initialSecret,
            scenario
        )
        XCTAssertFalse(app.configuration.videoAnalyzerLegacyServerTokenCleared, scenario)
        let persisted = await store.snapshot()
        XCTAssertEqual(
            persisted.pluginConfigurationValues["fixture.concurrent"]?[scenario],
            "concurrent-value",
            scenario
        )
        XCTAssertEqual(
            persisted.localPluginSecrets[Self.pluginID]?["serverToken"],
            initialSecret,
            scenario
        )
        XCTAssertFalse(persisted.videoAnalyzerLegacyServerTokenCleared, scenario)
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderLocalCredentialApp-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let pluginID = "dev.openfinder.plugins.video-analyzer"
    private static let videoAnalyzerManifest = PluginManifest(
        schemaVersion: 2,
        id: pluginID,
        name: "Video Analyzer",
        version: "0.1.0",
        description: nil,
        author: nil,
        execution: .http(protocolVersion: 1, endpointConfigurationKey: "serverURL", tokenSecretKey: "serverToken"),
        actions: [],
        permissions: .init(
            readFiles: "selected", writeFiles: "taskOutput",
            network: .init(required: true, hosts: ["127.0.0.1"]),
            clipboardWrite: false, clipboardRead: false, keychainSecrets: [],
            remoteAccounts: false, runExternalCommands: false,
            localSecrets: ["serverToken"]
        ),
        configuration: [.init(key: "serverURL", type: "url", title: "Server URL", required: true)]
    )
    private static let legacyManifest = PluginManifest(
        schemaVersion: 1,
        id: "fixture.legacy-plugin",
        name: "Legacy",
        version: "1.0.0",
        description: nil,
        author: nil,
        runtime: .shell,
        entry: "run.sh",
        actions: [],
        permissions: .init(
            readFiles: "none", writeFiles: "none", network: .init(),
            clipboardWrite: false, clipboardRead: false, keychainSecrets: ["apiToken"],
            remoteAccounts: false, runExternalCommands: false
        ),
        configuration: []
    )
}

private actor ControllableConfigurationStore: AppConfigurationStore {
    private var persisted = AppConfiguration()
    private var nextSaveShouldFail = false
    private var nextSaveShouldSuspend = false
    private var saveIsSuspended = false
    private var saveStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveResumeContinuation: CheckedContinuation<Void, Never>?

    func load() async throws -> AppConfiguration { persisted }

    func save(_ configuration: AppConfiguration) async throws {
        if nextSaveShouldFail {
            nextSaveShouldFail = false
            throw ControllableConfigurationStoreError.saveRejected
        }
        if nextSaveShouldSuspend {
            nextSaveShouldSuspend = false
            saveIsSuspended = true
            let waiters = saveStartedWaiters
            saveStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                saveResumeContinuation = continuation
            }
            saveIsSuspended = false
        }
        persisted = configuration
    }

    func failNextSave() {
        nextSaveShouldFail = true
    }

    func suspendNextSave() {
        nextSaveShouldSuspend = true
    }

    func waitUntilSaveIsSuspended() async {
        if saveIsSuspended { return }
        await withCheckedContinuation { continuation in
            saveStartedWaiters.append(continuation)
        }
    }

    func resumeSuspendedSave() {
        saveResumeContinuation?.resume()
        saveResumeContinuation = nil
    }

    func snapshot() -> AppConfiguration { persisted }
}

private enum ControllableConfigurationStoreError: LocalizedError {
    case saveRejected

    var errorDescription: String? { "fixture persistence failure" }
}

private final class RecordingPluginKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var sets: [String] = []
    private var deletes: [String] = []

    var setKeys: [String] { lock.withLock { sets } }
    var deletedKeys: [String] { lock.withLock { deletes } }

    func secret(for key: String) throws -> String? { lock.withLock { storage[key] } }

    func setSecret(_ secret: String, for key: String) throws {
        lock.withLock {
            storage[key] = secret
            sets.append(key)
        }
    }

    func deleteSecret(for key: String) throws {
        lock.withLock {
            storage.removeValue(forKey: key)
            deletes.append(key)
        }
    }

    func resetRecordedMutations() {
        lock.withLock {
            sets = []
            deletes = []
        }
    }
}
