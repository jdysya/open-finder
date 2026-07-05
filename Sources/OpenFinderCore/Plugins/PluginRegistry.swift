import Foundation

public struct LoadedPlugin: Identifiable, Hashable, Sendable {
    public let id: String
    public let manifest: PluginManifest
    public let directory: URL

    public init(manifest: PluginManifest, directory: URL) {
        self.id = manifest.id
        self.manifest = manifest
        self.directory = directory
    }
}

public struct PluginRegistry: Sendable {
    public init() {}

    public func scan(directory: URL) throws -> [LoadedPlugin] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        return try children.compactMap { pluginURL in
            let manifestURL = pluginURL.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder.openFinder.decode(PluginManifest.self, from: data)
            return LoadedPlugin(manifest: manifest, directory: pluginURL)
        }.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }
}
