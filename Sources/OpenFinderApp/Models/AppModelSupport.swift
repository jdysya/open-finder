import AppKit
import Foundation
import OpenFinderCore

actor ConfigurationPersistenceGate {
    private var isAcquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isAcquired {
            isAcquired = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isAcquired = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

extension AppModel {
    func loadInitialState() async {
        guard !didLoadInitialState else { return }
        didLoadInitialState = true
        if let loadedConfiguration = try? await configurationStore.load() {
            configuration = loadedConfiguration
        }
        await taskQueue.updateMaxConcurrentTasks(configuration.maxConcurrentTasks)
        leftPane.showHiddenFiles = configuration.defaultShowHiddenFiles
        rightPane.showHiddenFiles = configuration.defaultShowHiddenFiles
        await leftPane.refresh()
        await rightPane.refresh()
        loadPlugins()
        await migrateLegacyLocalPluginSecrets(in: loadedPlugins)
        remoteAccounts = remoteDirectory.all()
        await refreshTasks()
    }

    func revealSelectedInFinder() {
        activeBrowser.revealSelectedInFinder()
    }

    func openSelectedInTerminal() {
        activeBrowser.openSelectedInTerminal()
    }

    func quickLookSelected() {
        activeBrowser.quickLookSelected()
    }

    func saveConfiguration() {
        let configuration = configuration
        let store = configurationStore
        let previous = configurationSaveTask
        configurationSaveTask = Task {
            await previous?.value
            try? await store.save(configuration)
        }
    }

    func flushConfigurationSaves() async {
        await configurationSaveTask?.value
    }

    static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("OpenFinder", isDirectory: true)
    }
}
