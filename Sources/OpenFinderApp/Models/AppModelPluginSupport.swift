import Foundation
import OpenFinderCore

extension AppModel {
    func loadPlugins() {
        let projectPlugins = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ExamplePlugins", isDirectory: true)
        let bundledPlugins = Bundle.main.resourceURL?
            .appendingPathComponent("BuiltinPlugins", isDirectory: true)
        let appSupportPlugins = Self.applicationSupportDirectory()
            .appendingPathComponent("Plugins", isDirectory: true)
        let locations: [(URL, PluginSource)] = [
            (projectPlugins, .development),
            (appSupportPlugins, .user)
        ] + (bundledPlugins.map { [($0, .builtIn)] } ?? [])
        let catalog = pluginManagementService.scan(locations: locations)
        loadedPlugins = catalog.loaded
        pluginLoadDiagnostics = catalog.diagnostics
        statusMessage = catalog.diagnostics.isEmpty
            ? "Loaded \(catalog.loaded.count) plugins"
            : "Loaded \(catalog.loaded.count) plugins with \(catalog.diagnostics.count) diagnostic(s)"
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
        pluginConnectionStatuses[plugin.id] = .init(
            state: .connecting,
            guidance: "Checking the local plugin service…"
        )
        let status = await pluginManagementService.checkConnection(
            plugin,
            configuration: configuration
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
        let manifest = loadedPlugins.first(where: { $0.id == pluginID })?.manifest
        return pluginManagementService.isSecretConfigured(
            pluginID: pluginID,
            key: key,
            manifest: manifest
        )
    }

    @discardableResult
    func setPluginSecret(_ secret: String, pluginID: String, key: String) async -> Bool {
        if let manifest = loadedPlugins.first(where: { $0.id == pluginID })?.manifest {
            return await setPluginSecret(secret, for: manifest, key: key)
        }
        return await applyPluginSecretResult(await pluginManagementService.setSecret(
            secret,
            pluginID: pluginID,
            key: key,
            storage: .keychain
        ))
    }

    @discardableResult
    func setPluginSecret(_ secret: String, for manifest: PluginManifest, key: String) async -> Bool {
        await applyPluginSecretResult(await pluginManagementService.setSecret(
            secret,
            manifest: manifest,
            key: key
        ))
    }

    func configuredPluginSecretReferences(for manifest: PluginManifest) -> [String: String] {
        pluginManagementService.configuredSecretReferences(for: manifest)
    }

    private func applyPluginSecretResult(_ result: PluginSecretMutationResult) async -> Bool {
        if let projectedConfiguration = result.configuration {
            configuration = projectedConfiguration
        }
        statusMessage = result.message
        objectWillChange.send()
        return result.succeeded
    }
}
