import Foundation

public struct ResolvedPluginConfiguration: Equatable, Sendable {
    public let config: [String: String]
    public let secrets: [String: PluginSecretReference]

    public init(config: [String: String], secrets: [String: PluginSecretReference]) {
        self.config = config
        self.secrets = secrets
    }
}

public enum PluginConfigurationResolver {
    public static func resolve(
        manifest: PluginManifest,
        values: [String: String],
        secretReferences: [String: String]
    ) -> ResolvedPluginConfiguration {
        var config: [String: String] = [:]
        for field in manifest.configuration {
            let value = values[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                config[field.key] = value
            } else if let defaultValue = field.defaultValue, !defaultValue.isEmpty {
                config[field.key] = defaultValue
            }
        }

        var secrets: [String: PluginSecretReference] = [:]
        for key in manifest.permissions.keychainSecrets {
            if let reference = secretReferences[key], !reference.isEmpty {
                secrets[key] = PluginSecretReference(env: reference)
            }
        }

        return ResolvedPluginConfiguration(config: config, secrets: secrets)
    }
}
