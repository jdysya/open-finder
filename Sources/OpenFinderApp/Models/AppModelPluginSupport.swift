import Foundation
import OpenFinderCore

extension AppModel {
    func loadPlugins() {
        var plugins: [LoadedPlugin] = []
        let projectPlugins = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ExamplePlugins", isDirectory: true)
        let bundledPlugins = Bundle.main.resourceURL?
            .appendingPathComponent("BuiltinPlugins", isDirectory: true)
        let appSupportPlugins = Self.applicationSupportDirectory()
            .appendingPathComponent("Plugins", isDirectory: true)
        for directory in [projectPlugins, bundledPlugins, appSupportPlugins].compactMap({ $0 }) {
            if let scanned = try? pluginRegistry.scan(directory: directory) {
                plugins.append(contentsOf: scanned)
            }
        }
        loadedPlugins = Array(Dictionary(grouping: plugins, by: \.id).compactMap { $0.value.first })
    }

    func pluginActions(for items: [FileItem]) -> [(LoadedPlugin, PluginActionManifest)] {
        loadedPlugins.flatMap { plugin in
            PluginMatcher.actions(in: plugin.manifest, matching: items).map { (plugin, $0) }
        }
    }

    func pluginConnectionStatus(for plugin: LoadedPlugin) -> PluginConnectionStatus? {
        pluginConnectionStatuses[plugin.id]
    }

    @discardableResult
    func checkPluginConnection(_ plugin: LoadedPlugin) async -> PluginConnectionStatus {
        let connecting = PluginConnectionStatus(
            state: .connecting,
            guidance: "Checking the local plugin service…"
        )
        pluginConnectionStatuses[plugin.id] = connecting
        let resolved = PluginConfigurationResolver.resolve(
            manifest: plugin.manifest,
            values: configuration.pluginConfigurationValues[plugin.id] ?? [:],
            secretReferences: configuredPluginSecretReferences(for: plugin.manifest)
        )
        let status = await pluginConnectionChecker.check(
            manifest: plugin.manifest,
            values: resolved.config,
            secretReferences: configuredPluginSecretReferences(for: plugin.manifest)
        )
        pluginConnectionStatuses[plugin.id] = status
        return status
    }

    func pluginConfigValue(pluginID: String, key: String) -> String {
        configuration.pluginConfigurationValues[pluginID]?[key] ?? ""
    }

    func setPluginConfigValue(_ value: String, pluginID: String, key: String) {
        var next = configuration
        var pluginValues = next.pluginConfigurationValues[pluginID] ?? [:]
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pluginValues.removeValue(forKey: key)
        } else {
            pluginValues[key] = value
        }
        next.pluginConfigurationValues[pluginID] = pluginValues.isEmpty ? nil : pluginValues
        configuration = next
    }

    func pluginSecretConfigured(pluginID: String, key: String) -> Bool {
        (try? keychainStore.secret(for: pluginSecretReference(pluginID: pluginID, key: key))) != nil
    }

    func setPluginSecret(_ secret: String, pluginID: String, key: String) {
        do {
            let reference = pluginSecretReference(pluginID: pluginID, key: key)
            if secret.isEmpty {
                try keychainStore.deleteSecret(for: reference)
                statusMessage = "Cleared plugin secret \(key)"
            } else {
                try keychainStore.setSecret(secret, for: reference)
                statusMessage = "Saved plugin secret \(key)"
            }
            objectWillChange.send()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func configuredPluginSecretReferences(for manifest: PluginManifest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: manifest.permissions.keychainSecrets.compactMap { key in
            let reference = pluginSecretReference(pluginID: manifest.id, key: key)
            guard (try? keychainStore.secret(for: reference)) != nil else { return nil }
            return (key, reference)
        })
    }

    private func pluginSecretReference(pluginID: String, key: String) -> String {
        "plugin.\(pluginID).\(key)"
    }
}
