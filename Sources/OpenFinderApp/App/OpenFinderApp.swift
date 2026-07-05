import AppKit
import SwiftUI

final class OpenFinderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct OpenFinderApp: App {
    @NSApplicationDelegateAdaptor(OpenFinderAppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("OpenFinder", id: "main") {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .commands {
            OpenFinderCommands(app: appModel)
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
