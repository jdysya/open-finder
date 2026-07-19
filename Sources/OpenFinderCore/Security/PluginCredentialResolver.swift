import Foundation

public enum PluginSecretStorage: String, Codable, Hashable, Sendable {
    case keychain
    case localConfiguration
}

public enum PluginCredentialReference {
    private static let localConfigurationPrefix = "local-config.plugin.v1."

    public static func keychain(pluginID: String, key: String) -> String {
        "plugin.\(pluginID).\(key)"
    }

    public static func localConfiguration(pluginID: String, key: String) -> String {
        let pluginIDLength = pluginID.lengthOfBytes(using: .utf8)
        let keyLength = key.lengthOfBytes(using: .utf8)
        return "\(localConfigurationPrefix)\(pluginIDLength):\(pluginID)\(keyLength):\(key)"
    }

    static func isLocalConfiguration(_ reference: String) -> Bool {
        reference.hasPrefix(localConfigurationPrefix)
    }
}

public final class LocalPluginCredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var secretsByReference: [String: String]

    public init(pluginSecrets: [String: [String: String]] = [:]) {
        secretsByReference = Self.flatten(pluginSecrets)
    }

    public func replace(pluginSecrets: [String: [String: String]]) {
        lock.withLock { secretsByReference = Self.flatten(pluginSecrets) }
    }

    public func secret(for reference: String) -> String? {
        lock.withLock { secretsByReference[reference] }
    }

    private static func flatten(_ pluginSecrets: [String: [String: String]]) -> [String: String] {
        var flattened: [String: String] = [:]
        for (pluginID, secrets) in pluginSecrets {
            for (key, value) in secrets where !value.isEmpty {
                flattened[PluginCredentialReference.localConfiguration(pluginID: pluginID, key: key)] = value
            }
        }
        return flattened
    }
}

public struct PluginCredentialResolver: Sendable {
    private let keychainStore: any KeychainStore
    private let localStore: LocalPluginCredentialStore

    public init(keychainStore: any KeychainStore, localStore: LocalPluginCredentialStore) {
        self.keychainStore = keychainStore
        self.localStore = localStore
    }

    public func secret(for reference: String) throws -> String? {
        if PluginCredentialReference.isLocalConfiguration(reference) {
            return localStore.secret(for: reference)
        }
        return try keychainStore.secret(for: reference)
    }
}
