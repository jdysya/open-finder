import Foundation
import OpenFinderCore

@MainActor
final class RuntimeConfigurationService {
    private let store: any AppConfigurationStore
    private let taskQueue: TaskQueueService
    private var processRunner: ConfigurableProcessPluginRunner?
    private var configuration = AppConfiguration()
    private var saveTask: Task<Void, Never>?
    private var runtimeUpdateTask: Task<Void, Never>?
    private(set) var isPersistenceDeferred = false
    private var saveWasDeferred = false

    init(
        store: any AppConfigurationStore,
        taskQueue: TaskQueueService,
        processRunner: ConfigurableProcessPluginRunner? = nil
    ) {
        self.store = store
        self.taskQueue = taskQueue
        self.processRunner = processRunner
    }

    func attach(processRunner: ConfigurableProcessPluginRunner?) {
        self.processRunner = processRunner
    }

    func load() async throws -> AppConfiguration {
        let loaded = try await store.load()
        configuration = loaded
        scheduleRuntimeUpdate(for: loaded)
        await runtimeUpdateTask?.value
        return loaded
    }

    func publish(_ next: AppConfiguration) {
        guard next != configuration else { return }
        configuration = next
        scheduleRuntimeUpdate(for: next)
        if isPersistenceDeferred {
            saveWasDeferred = true
        } else {
            scheduleSave(next)
        }
    }

    func saveCurrent() {
        if isPersistenceDeferred {
            saveWasDeferred = true
        } else {
            scheduleSave(configuration)
        }
    }

    func flush() async {
        await saveTask?.value
        await runtimeUpdateTask?.value
    }

    func persistLocalSecret(
        _ secret: String,
        pluginID: String,
        key: String
    ) async -> LocalSecretPersistenceResult {
        isPersistenceDeferred = true
        await flush()
        let previouslyPersisted = configuration
        let previousValue = configuration.localPluginSecrets[pluginID]?[key]
        var attempted = configuration
        Self.updateLocalSecret(secret, pluginID: pluginID, key: key, in: &attempted)
        configuration = attempted

        do {
            try await store.save(attempted)
            var latest = configuration
            Self.updateLocalSecret(secret, pluginID: pluginID, key: key, in: &latest)
            if latest != attempted {
                try await store.save(latest)
            }
            configuration = latest
            isPersistenceDeferred = false
            saveWasDeferred = false
            return .init(succeeded: true, configuration: latest, error: nil)
        } catch {
            var restored = configuration
            Self.restoreLocalSecret(
                previousValue,
                pluginID: pluginID,
                key: key,
                in: &restored
            )
            configuration = restored
            isPersistenceDeferred = false
            let requiresSave = saveWasDeferred || restored != previouslyPersisted
            saveWasDeferred = false
            if requiresSave {
                scheduleSave(restored)
            }
            return .init(succeeded: false, configuration: restored, error: error)
        }
    }

    private func scheduleSave(_ snapshot: AppConfiguration) {
        let previous = saveTask
        let store = store
        saveTask = Task {
            await previous?.value
            try? await store.save(snapshot)
        }
    }

    private func scheduleRuntimeUpdate(for snapshot: AppConfiguration) {
        let previous = runtimeUpdateTask
        let queue = taskQueue
        let processRunner = processRunner
        runtimeUpdateTask = Task {
            await previous?.value
            await queue.updateMaxConcurrentTasks(snapshot.maxConcurrentTasks)
            if let processRunner {
                await processRunner.update(
                    python3Path: snapshot.python3Path,
                    nodePath: snapshot.nodePath
                )
            }
        }
    }

    private static func updateLocalSecret(
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
    }

    private static func restoreLocalSecret(
        _ previousValue: String?,
        pluginID: String,
        key: String,
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
    }
}

struct LocalSecretPersistenceResult {
    let succeeded: Bool
    let configuration: AppConfiguration
    let error: (any Error)?
}
