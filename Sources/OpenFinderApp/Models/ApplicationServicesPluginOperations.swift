import Foundation
import OpenFinderCore

@MainActor
extension ApplicationServices {
    func loadConfiguration() async throws -> AppConfiguration {
        try await configurationService.load()
    }

    func publish(configuration: AppConfiguration) {
        configurationService.publish(configuration)
        pluginService.publish(configuration: configuration)
    }

    func saveConfiguration() {
        configurationService.saveCurrent()
    }

    func flushConfigurationSaves() async {
        await configurationService.flush()
    }

    func scanPlugins() -> PluginScanResult {
        let projectPlugins = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ExamplePlugins", isDirectory: true)
        let bundledPlugins = Bundle.main.resourceURL?
            .appendingPathComponent("BuiltinPlugins", isDirectory: true)
        let appSupportPlugins = Self.applicationSupportDirectory()
            .appendingPathComponent("Plugins", isDirectory: true)
        let locations: [(URL, PluginSource)] = [
            (projectPlugins, .development),
            (appSupportPlugins, .user),
        ] + (bundledPlugins.map { [($0, .builtIn)] } ?? [])
        return pluginService.scan(locations: locations)
    }

    func registerPlugins(_ plugins: [LoadedPlugin]) async {
        await pluginResolver.register(plugins)
    }

    func pluginActions(
        in plugins: [LoadedPlugin],
        for items: [FileItem]
    ) -> [(LoadedPlugin, PluginActionManifest)] {
        plugins.flatMap { plugin in
            PluginMatcher.actions(in: plugin.manifest, matching: items).map { (plugin, $0) }
        }
    }

    func checkPluginConnection(
        _ plugin: LoadedPlugin,
        configuration: AppConfiguration
    ) async -> PluginConnectionStatus {
        await pluginService.checkConnection(plugin, configuration: configuration)
    }

    func pluginSecretConfigured(
        pluginID: String,
        key: String,
        manifest: PluginManifest?
    ) -> Bool {
        pluginService.isSecretConfigured(
            pluginID: pluginID,
            key: key,
            manifest: manifest
        )
    }

    func setPluginSecret(
        _ secret: String,
        pluginID: String,
        key: String
    ) async -> PluginSecretMutationResult {
        await pluginService.setSecret(
            secret,
            pluginID: pluginID,
            key: key,
            storage: .keychain
        )
    }

    func setPluginSecret(
        _ secret: String,
        manifest: PluginManifest,
        key: String
    ) async -> PluginSecretMutationResult {
        await pluginService.setSecret(secret, manifest: manifest, key: key)
    }

    func configuredPluginSecretReferences(for manifest: PluginManifest) -> [String: String] {
        pluginService.configuredSecretReferences(for: manifest)
    }
}
