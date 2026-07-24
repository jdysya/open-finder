import Foundation
import OpenFinderCore

actor PluginResultProjectionBox {
    private var storedProjections: [UUID: PluginResultProjection] = [:]

    func store(_ projection: PluginResultProjection, for taskID: UUID) {
        storedProjections[taskID] = projection
    }

    func take(for taskID: UUID) -> PluginResultProjection? {
        storedProjections.removeValue(forKey: taskID)
    }
}

actor AppPluginTaskResolver {
    private var pluginsByIdentity: [String: LoadedPlugin] = [:]

    func register(_ plugin: LoadedPlugin) {
        pluginsByIdentity[key(plugin.id, plugin.manifest.version)] = plugin
    }

    func register(_ plugins: [LoadedPlugin]) {
        for plugin in plugins {
            register(plugin)
        }
    }

    func resolve(pluginID: String, pluginVersion: String) throws -> LoadedPlugin {
        guard let plugin = pluginsByIdentity[key(pluginID, pluginVersion)] else {
            throw PluginTaskResolutionError.versionUnavailable(
                pluginID: pluginID,
                version: pluginVersion
            )
        }
        return plugin
    }

    private func key(_ pluginID: String, _ pluginVersion: String) -> String {
        "\(pluginID)\u{0}\(pluginVersion)"
    }
}
