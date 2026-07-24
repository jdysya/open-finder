import AppKit
import Foundation
import OpenFinderCore

extension AppModel {
    func loadInitialState() async {
        guard !didLoadInitialState else { return }
        didLoadInitialState = true
        if let loadedConfiguration = try? await runtimeConfigurationService.load() {
            configuration = loadedConfiguration
        }
        leftPane.showHiddenFiles = configuration.defaultShowHiddenFiles
        rightPane.showHiddenFiles = configuration.defaultShowHiddenFiles
        await leftPane.refresh()
        await rightPane.refresh()
        loadPlugins()
        remoteAccounts = remoteAccountService.accounts()
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
        runtimeConfigurationService.saveCurrent()
    }

    func flushConfigurationSaves() async {
        await runtimeConfigurationService.flush()
    }

    static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("OpenFinder", isDirectory: true)
    }
}
