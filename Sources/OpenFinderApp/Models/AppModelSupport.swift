import AppKit
import Foundation
import OpenFinderCore

extension AppModel {
    func loadInitialState() async {
        guard !didLoadInitialState else { return }
        didLoadInitialState = true
        if let loadedConfiguration = try? await configurationStore.load() {
            configuration = loadedConfiguration
        }
        await leftPane.refresh()
        await rightPane.refresh()
        loadPlugins()
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
        Task {
            try? await store.save(configuration)
        }
    }

    static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("OpenFinder", isDirectory: true)
    }
}
