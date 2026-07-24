import Foundation
import OpenFinderCore

extension AppModel {
    func loadInitialState() async {
        guard !didLoadInitialState else { return }
        didLoadInitialState = true
        if let loadedConfiguration = try? await services.loadConfiguration() {
            configuration = loadedConfiguration
        }
        leftPane.showHiddenFiles = configuration.defaultShowHiddenFiles
        rightPane.showHiddenFiles = configuration.defaultShowHiddenFiles
        await leftPane.refresh()
        await rightPane.refresh()
        loadPlugins()
        remoteAccounts = services.remoteAccounts()
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
        services.saveConfiguration()
    }

    func flushConfigurationSaves() async {
        await services.flushConfigurationSaves()
    }

    static func applicationSupportDirectory() -> URL {
        ApplicationServices.applicationSupportDirectory()
    }
}
