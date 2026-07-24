import Foundation
import OpenFinderCore

struct PluginSecretMutationResult {
    let succeeded: Bool
    let configuration: AppConfiguration?
    let message: String
}

@MainActor
final class PluginManagementService {
    private let configurationService: RuntimeConfigurationService
    private let registry: PluginRegistry
    private let keychainStore: any KeychainStore
    private let localCredentialStore: LocalPluginCredentialStore
    private let resolver: PluginCredentialResolver
    private let connectionChecker: any PluginConnectionChecking

    init(
        configurationService: RuntimeConfigurationService,
        registry: PluginRegistry = PluginRegistry(),
        keychainStore: any KeychainStore,
        localCredentialStore: LocalPluginCredentialStore,
        connectionChecker: (any PluginConnectionChecking)? = nil
    ) {
        self.configurationService = configurationService
        self.registry = registry
        self.keychainStore = keychainStore
        self.localCredentialStore = localCredentialStore
        self.resolver = PluginCredentialResolver(
            keychainStore: keychainStore,
            localStore: localCredentialStore
        )
        self.connectionChecker = connectionChecker
            ?? HTTPPluginConnectionProbe(credentialResolver: resolver)
    }

    var credentialResolver: PluginCredentialResolver { resolver }
    var credentialStore: any KeychainStore { keychainStore }
    var connectionChecking: any PluginConnectionChecking { connectionChecker }

    func publish(configuration: AppConfiguration) {
        localCredentialStore.replace(pluginSecrets: configuration.localPluginSecrets)
    }

    func scan(locations: [(URL, PluginSource)]) -> PluginScanResult {
        var results: [PluginScanResult] = []
        for (directory, source) in locations {
            do {
                results.append(try registry.scanWithDiagnostics(
                    directory: directory,
                    source: source
                ))
            } catch {
                results.append(.init(loaded: [], diagnostics: [.init(
                    kind: .invalidPackage,
                    source: source,
                    pluginDirectory: directory,
                    message: "Could not scan \(source.displayName) plugins: "
                        + Self.singleLine(error.localizedDescription)
                )]))
            }
        }
        let catalog = registry.resolveCatalog(from: results)
        return .init(
            loaded: catalog.loaded,
            diagnostics: catalog.diagnostics.map {
                .init(
                    kind: $0.kind,
                    source: $0.source,
                    pluginDirectory: $0.pluginDirectory,
                    pluginID: $0.pluginID,
                    message: Self.singleLine($0.message)
                )
            }
        )
    }

    func resolvedConfiguration(
        for manifest: PluginManifest,
        configuration: AppConfiguration
    ) -> ResolvedPluginConfiguration {
        PluginConfigurationResolver.resolve(
            manifest: manifest,
            values: configuration.pluginConfigurationValues[manifest.id] ?? [:],
            secretReferences: configuredSecretReferences(for: manifest)
        )
    }

    func configuredSecretReferences(for manifest: PluginManifest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: manifest.permissions.secretKeys.compactMap { key in
            let reference: String
            switch manifest.permissions.storage(for: key) {
            case .localConfiguration:
                reference = PluginCredentialReference.localConfiguration(
                    pluginID: manifest.id,
                    key: key
                )
                guard localCredentialStore.secret(for: reference) != nil else { return nil }
            case .keychain:
                reference = PluginCredentialReference.keychain(pluginID: manifest.id, key: key)
                guard (try? keychainStore.secret(for: reference)) != nil else { return nil }
            case nil:
                return nil
            }
            return (key, reference)
        })
    }

    func isSecretConfigured(pluginID: String, key: String, manifest: PluginManifest?) -> Bool {
        guard let manifest else {
            let reference = PluginCredentialReference.keychain(pluginID: pluginID, key: key)
            return (try? keychainStore.secret(for: reference)) != nil
        }
        return configuredSecretReferences(for: manifest)[key] != nil
    }

    func setSecret(
        _ secret: String,
        manifest: PluginManifest,
        key: String
    ) async -> PluginSecretMutationResult {
        guard let storage = manifest.permissions.storage(for: key) else {
            return .init(
                succeeded: false,
                configuration: nil,
                message: "Plugin secret \(key) has no declared storage."
            )
        }
        return await setSecret(
            secret,
            pluginID: manifest.id,
            key: key,
            storage: storage
        )
    }

    func setSecret(
        _ secret: String,
        pluginID: String,
        key: String,
        storage: PluginSecretStorage
    ) async -> PluginSecretMutationResult {
        if storage == .localConfiguration {
            let result = await configurationService.persistLocalSecret(
                secret,
                pluginID: pluginID,
                key: key
            )
            publish(configuration: result.configuration)
            if result.succeeded {
                return .init(
                    succeeded: true,
                    configuration: result.configuration,
                    message: secret.isEmpty
                        ? "Cleared plugin secret \(key) from secured local config"
                        : "Saved plugin secret \(key) in secured local config"
                )
            }
            let action = secret.isEmpty ? "clear" : "save"
            return .init(
                succeeded: false,
                configuration: result.configuration,
                message: "Could not \(action) plugin secret \(key) in secured local config. "
                    + "Check that OpenFinder can write its Application Support directory, then try again. "
                    + "(\(Self.redactedError(result.error, secret: secret)))"
            )
        }

        do {
            let reference = PluginCredentialReference.keychain(pluginID: pluginID, key: key)
            if secret.isEmpty {
                try keychainStore.deleteSecret(for: reference)
            } else {
                try keychainStore.setSecret(secret, for: reference)
            }
            return .init(
                succeeded: true,
                configuration: nil,
                message: secret.isEmpty
                    ? "Cleared plugin secret \(key) from Keychain"
                    : "Saved plugin secret \(key) in Keychain"
            )
        } catch {
            return .init(
                succeeded: false,
                configuration: nil,
                message: Self.redactedError(error, secret: secret)
            )
        }
    }

    func checkConnection(
        _ plugin: LoadedPlugin,
        configuration: AppConfiguration
    ) async -> PluginConnectionStatus {
        let resolved = resolvedConfiguration(for: plugin.manifest, configuration: configuration)
        return await connectionChecker.check(
            manifest: plugin.manifest,
            values: resolved.config,
            secretReferences: configuredSecretReferences(for: plugin.manifest)
        )
    }

    func setStoredSecret(_ secret: String, for reference: String) throws {
        try keychainStore.setSecret(secret, for: reference)
    }

    func deleteStoredSecret(for reference: String) throws {
        try keychainStore.deleteSecret(for: reference)
    }

    private static func singleLine(_ message: String) -> String {
        message.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
    }

    private static func redactedError(_ error: (any Error)?, secret: String) -> String {
        let message = singleLine(error?.localizedDescription ?? "Unknown persistence error")
        guard !secret.isEmpty else { return message }
        return message.replacingOccurrences(of: secret, with: "<redacted>")
    }
}
