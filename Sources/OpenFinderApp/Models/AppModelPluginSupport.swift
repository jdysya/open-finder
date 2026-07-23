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

        var scanResults: [PluginScanResult] = []
        for (directory, source) in locations {
            do {
                scanResults.append(try pluginRegistry.scanWithDiagnostics(
                    directory: directory,
                    source: source
                ))
            } catch {
                scanResults.append(.init(loaded: [], diagnostics: [.init(
                    kind: .invalidPackage,
                    source: source,
                    pluginDirectory: directory,
                    message: "Could not scan \(source.displayName) plugins: \(error.localizedDescription)"
                )]))
            }
        }
        let catalog = pluginRegistry.resolveCatalog(from: scanResults)
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
        guard let manifest = loadedPlugins.first(where: { $0.id == pluginID })?.manifest else {
            return (try? keychainStore.secret(
                for: PluginCredentialReference.keychain(pluginID: pluginID, key: key)
            )) != nil
        }
        return configuredPluginSecretReferences(for: manifest)[key] != nil
    }

    @discardableResult
    func setPluginSecret(_ secret: String, pluginID: String, key: String) async -> Bool {
        let storage = loadedPlugins.first(where: { $0.id == pluginID })?
            .manifest.permissions.storage(for: key) ?? .keychain
        return await setPluginSecret(secret, pluginID: pluginID, key: key, storage: storage)
    }

    @discardableResult
    func setPluginSecret(_ secret: String, for manifest: PluginManifest, key: String) async -> Bool {
        guard let storage = manifest.permissions.storage(for: key) else {
            statusMessage = "Plugin secret \(key) has no declared storage."
            return false
        }
        return await setPluginSecret(secret, pluginID: manifest.id, key: key, storage: storage)
    }

    private func setPluginSecret(
        _ secret: String,
        pluginID: String,
        key: String,
        storage: PluginSecretStorage
    ) async -> Bool {
        if storage == .localConfiguration {
            await configurationPersistenceGate.acquire()
            let result = await persistLocalPluginSecret(secret, pluginID: pluginID, key: key)
            await configurationPersistenceGate.release()
            return result
        }

        do {
            let reference = PluginCredentialReference.keychain(pluginID: pluginID, key: key)
            if secret.isEmpty {
                try keychainStore.deleteSecret(for: reference)
                statusMessage = "Cleared plugin secret \(key) from Keychain"
            } else {
                try keychainStore.setSecret(secret, for: reference)
                statusMessage = "Saved plugin secret \(key) in Keychain"
            }
            objectWillChange.send()
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func persistLocalPluginSecret(_ secret: String, pluginID: String, key: String) async -> Bool {
        configurationPersistenceIsDeferred = true
        await flushConfigurationSaves()
        let saveWasDeferredDuringFlush = configurationSaveWasDeferred
        let previouslyPersisted = configuration
        let previousValue = configuration.localPluginSecrets[pluginID]?[key]
        let previousLegacyClear = configuration.videoAnalyzerLegacyServerTokenCleared

        var next = configuration
        updateLocalPluginSecret(secret, pluginID: pluginID, key: key, in: &next)
        configuration = next

        do {
            try await configurationStore.save(next)
            let merge = await persistConfigurationChangesMadeDuringSave(after: next)
            finishConfigurationPersistenceDeferral(lastPersisted: merge.persisted)
            statusMessage = secret.isEmpty
                ? "Cleared plugin secret \(key) from secured local config"
                : "Saved plugin secret \(key) in secured local config"
            if let mergeFailure = merge.failure {
                statusMessage += "; newer settings are pending another save: \(mergeFailure.localizedDescription)"
            }
            objectWillChange.send()
            return true
        } catch {
            var restored = configuration
            restoreLocalPluginSecret(
                previousValue,
                pluginID: pluginID,
                key: key,
                previousLegacyClear: previousLegacyClear,
                in: &restored
            )
            configuration = restored
            finishConfigurationPersistenceDeferral(
                lastPersisted: previouslyPersisted,
                forceSave: saveWasDeferredDuringFlush
            )
            let action = secret.isEmpty ? "clear" : "save"
            statusMessage = "Could not \(action) plugin secret \(key) in secured local config. "
                + "Check that OpenFinder can write its Application Support directory, then try again. "
                + "(\(error.localizedDescription))"
            objectWillChange.send()
            return false
        }
    }

    func configuredPluginSecretReferences(for manifest: PluginManifest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: manifest.permissions.secretKeys.compactMap { key -> (String, String)? in
            switch manifest.permissions.storage(for: key) {
            case .localConfiguration:
                let reference = PluginCredentialReference.localConfiguration(pluginID: manifest.id, key: key)
                if localPluginCredentialStore.secret(for: reference) != nil { return (key, reference) }
                guard isVideoAnalyzerLegacyFallback(manifest: manifest, key: key) else { return nil }
                guard !configuration.videoAnalyzerLegacyServerTokenCleared else { return nil }
                let legacyReference = PluginCredentialReference.keychain(pluginID: manifest.id, key: key)
                guard (try? keychainStore.secret(for: legacyReference)) != nil else { return nil }
                return (key, legacyReference)
            case .keychain:
                let reference = PluginCredentialReference.keychain(pluginID: manifest.id, key: key)
                guard (try? keychainStore.secret(for: reference)) != nil else { return nil }
                return (key, reference)
            case nil:
                return nil
            }
        })
    }

    func migrateLegacyLocalPluginSecrets(in plugins: [LoadedPlugin]) async {
        await configurationPersistenceGate.acquire()
        configurationPersistenceIsDeferred = true
        await flushConfigurationSaves()
        let saveWasDeferredDuringFlush = configurationSaveWasDeferred
        let previouslyPersisted = configuration
        var next = configuration
        var changed = false
        for plugin in plugins {
            for key in plugin.manifest.permissions.localSecrets
                where isVideoAnalyzerLegacyFallback(manifest: plugin.manifest, key: key) {
                guard !next.videoAnalyzerLegacyServerTokenCleared else { continue }
                guard next.localPluginSecrets[plugin.id]?[key]?.isEmpty != false else { continue }
                let legacyReference = PluginCredentialReference.keychain(pluginID: plugin.id, key: key)
                guard let value = try? keychainStore.secret(for: legacyReference),
                      !value.isEmpty else { continue }
                next.localPluginSecrets[plugin.id, default: [:]][key] = value
                changed = true
            }
        }
        guard changed else {
            finishConfigurationPersistenceDeferral(
                lastPersisted: previouslyPersisted,
                forceSave: configurationSaveWasDeferred
            )
            await configurationPersistenceGate.release()
            return
        }
        configuration = next
        do {
            try await configurationStore.save(next)
            let merge = await persistConfigurationChangesMadeDuringSave(after: next)
            finishConfigurationPersistenceDeferral(lastPersisted: merge.persisted)
            statusMessage = "Migrated the Video Analyzer server token to secured local config"
            if let mergeFailure = merge.failure {
                statusMessage += "; newer settings are pending another save: \(mergeFailure.localizedDescription)"
            }
        } catch {
            var restored = configuration
            restored.localPluginSecrets[Self.videoAnalyzerPluginID] =
                previouslyPersisted.localPluginSecrets[Self.videoAnalyzerPluginID]
            configuration = restored
            finishConfigurationPersistenceDeferral(
                lastPersisted: previouslyPersisted,
                forceSave: saveWasDeferredDuringFlush
            )
            statusMessage = "Could not migrate the Video Analyzer server token to secured local config; the legacy credential remains available."
        }
        await configurationPersistenceGate.release()
    }

    private func updateLocalPluginSecret(
        _ secret: String,
        pluginID: String,
        key: String,
        in configuration: inout AppConfiguration
    ) {
        var secrets = configuration.localPluginSecrets[pluginID] ?? [:]
        if secret.isEmpty {
            secrets.removeValue(forKey: key)
        } else {
            secrets[key] = secret
        }
        configuration.localPluginSecrets[pluginID] = secrets.isEmpty ? nil : secrets
        if pluginID == Self.videoAnalyzerPluginID && key == "serverToken" {
            configuration.videoAnalyzerLegacyServerTokenCleared = secret.isEmpty
        }
    }

    private func restoreLocalPluginSecret(
        _ previousValue: String?,
        pluginID: String,
        key: String,
        previousLegacyClear: Bool,
        in configuration: inout AppConfiguration
    ) {
        if let previousValue {
            configuration.localPluginSecrets[pluginID, default: [:]][key] = previousValue
        } else {
            configuration.localPluginSecrets[pluginID]?[key] = nil
            if configuration.localPluginSecrets[pluginID]?.isEmpty == true {
                configuration.localPluginSecrets[pluginID] = nil
            }
        }
        configuration.videoAnalyzerLegacyServerTokenCleared = previousLegacyClear
    }

    private func persistConfigurationChangesMadeDuringSave(
        after initialConfiguration: AppConfiguration
    ) async -> (persisted: AppConfiguration, failure: (any Error)?) {
        guard configuration != initialConfiguration else {
            return (initialConfiguration, nil)
        }
        let latest = configuration
        do {
            try await configurationStore.save(latest)
            return (latest, nil)
        } catch {
            return (initialConfiguration, error)
        }
    }

    private func finishConfigurationPersistenceDeferral(
        lastPersisted: AppConfiguration,
        forceSave: Bool = false
    ) {
        configurationPersistenceIsDeferred = false
        configurationSaveWasDeferred = false
        if forceSave || configuration != lastPersisted {
            saveConfiguration()
        }
    }

    private func isVideoAnalyzerLegacyFallback(manifest: PluginManifest, key: String) -> Bool {
        manifest.id == Self.videoAnalyzerPluginID && key == "serverToken"
    }
}
