import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppLocalPluginSecretTests: XCTestCase {
    func testSecretNeverAppearsInPublishedOrPersistedTaskState() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = RecordingPluginKeychainStore()
        let app = makeApp(root: root, keychain: keychain)
        let plugin = LoadedPlugin(manifest: Self.keychainManifest, directory: root)
        app.loadedPlugins = [plugin]
        app.setPluginConfigValue("visible-value", pluginID: plugin.id, key: "setting")
        await app.flushConfigurationSaves()

        let saved = await app.setPluginSecret(
            "fixture-secret-never-publish",
            for: plugin.manifest,
            key: "apiToken"
        )
        await app.flushConfigurationSaves()

        XCTAssertTrue(saved)
        XCTAssertFalse(app.statusMessage.contains("fixture-secret-never-publish"))
        XCTAssertFalse(String(describing: app.taskRecords).contains("fixture-secret-never-publish"))
        XCTAssertFalse(String(describing: app.taskLogs).contains("fixture-secret-never-publish"))
        let persistedConfig = try Data(contentsOf: root.appendingPathComponent("config.json"))
        XCTAssertFalse(persistedConfig.contains(Data("fixture-secret-never-publish".utf8)))
        XCTAssertEqual(
            app.configuredPluginSecretReferences(for: plugin.manifest)["apiToken"],
            PluginCredentialReference.keychain(pluginID: plugin.id, key: "apiToken")
        )
    }

    func testGenericLocalSecretSaveAndClearUseSecuredConfiguration() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = RecordingPluginKeychainStore()
        let app = makeApp(root: root, keychain: keychain)
        let plugin = LoadedPlugin(manifest: Self.localManifest, directory: root)
        app.loadedPlugins = [plugin]

        let saved = await app.setPluginSecret(
            "fixture-local-value",
            for: plugin.manifest,
            key: "localToken"
        )
        XCTAssertTrue(saved)
        XCTAssertEqual(
            app.configuration.localPluginSecrets[plugin.id]?["localToken"],
            "fixture-local-value"
        )
        XCTAssertEqual(keychain.setKeys, [])
        let persisted = try await JSONConfigStore(
            url: root.appendingPathComponent("config.json")
        ).load()
        XCTAssertEqual(
            persisted.localPluginSecrets[plugin.id]?["localToken"],
            "fixture-local-value"
        )

        let cleared = await app.setPluginSecret("", for: plugin.manifest, key: "localToken")
        XCTAssertTrue(cleared)
        XCTAssertNil(app.configuration.localPluginSecrets[plugin.id])
        XCTAssertEqual(keychain.deletedKeys, [])
    }

    func testFailedLocalSaveRestoresPublishedAndResolverState() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FailingConfigurationStore()
        let keychain = RecordingPluginKeychainStore()
        let app = makeApp(root: root, keychain: keychain, configurationStore: store)
        let plugin = LoadedPlugin(manifest: Self.localManifest, directory: root)
        app.loadedPlugins = [plugin]

        let saved = await app.setPluginSecret(
            "fixture-rejected-value",
            for: plugin.manifest,
            key: "localToken"
        )

        XCTAssertFalse(saved)
        XCTAssertNil(app.configuration.localPluginSecrets[plugin.id])
        XCTAssertNil(app.configuredPluginSecretReferences(for: plugin.manifest)["localToken"])
        XCTAssertFalse(app.statusMessage.contains("fixture-rejected-value"))
    }

    private func makeApp(
        root: URL,
        keychain: RecordingPluginKeychainStore,
        configurationStore: (any AppConfigurationStore)? = nil
    ) -> AppModel {
        AppModel(
            remoteDirectory: RemoteAccountDirectory(
                storageURL: root.appendingPathComponent("accounts.json")
            ),
            configurationStore: configurationStore ?? JSONConfigStore(
                url: root.appendingPathComponent("config.json")
            ),
            keychainStore: keychain,
            startAutomatically: false
        )
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLocalPluginSecret-\(UUID())", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let keychainManifest = PluginManifest(
        schemaVersion: 1,
        id: "fixture.keychain-plugin",
        name: "Keychain Plugin",
        version: "1.0.0",
        description: nil,
        author: nil,
        runtime: .shell,
        entry: "run.sh",
        actions: [],
        permissions: .init(
            readFiles: "none",
            writeFiles: "none",
            network: .init(),
            clipboardWrite: false,
            clipboardRead: false,
            keychainSecrets: ["apiToken"],
            remoteAccounts: false,
            runExternalCommands: false
        ),
        configuration: []
    )

    private static let localManifest = PluginManifest(
        schemaVersion: 2,
        id: "fixture.local-plugin",
        name: "Local Plugin",
        version: "1.0.0",
        description: nil,
        author: nil,
        execution: .http(
            protocolVersion: 1,
            endpointConfigurationKey: "serverURL",
            tokenSecretKey: "localToken"
        ),
        actions: [],
        permissions: .init(
            readFiles: "none",
            writeFiles: "none",
            network: .init(required: true, hosts: ["127.0.0.1"]),
            clipboardWrite: false,
            clipboardRead: false,
            keychainSecrets: [],
            remoteAccounts: false,
            runExternalCommands: false,
            localSecrets: ["localToken"]
        ),
        configuration: [
            .init(key: "serverURL", type: "url", title: "Server URL", required: true)
        ]
    )
}

private actor FailingConfigurationStore: AppConfigurationStore {
    func load() async throws -> AppConfiguration { AppConfiguration() }
    func save(_ configuration: AppConfiguration) async throws {
        let leakedValue = configuration.localPluginSecrets.values
            .flatMap(\.values)
            .first ?? "missing"
        throw OpenFinderError.operationFailed("fixture persistence failure: \(leakedValue)")
    }
}

private final class RecordingPluginKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var sets: [String] = []
    private var deletes: [String] = []

    var setKeys: [String] { lock.withLock { sets } }
    var deletedKeys: [String] { lock.withLock { deletes } }

    func secret(for key: String) throws -> String? {
        lock.withLock { storage[key] }
    }

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
}
