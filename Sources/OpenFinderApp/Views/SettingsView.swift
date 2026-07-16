import OpenFinderCore
import SwiftUI

struct SettingsView: View {
    @State private var selectedSettingsSection: SettingsSection? = .general
    @State private var selectedConnectorID: RemoteConnectorID = .kodbox
    @State private var remoteName = ""
    @State private var remoteEndpoint = RemoteConnectorRegistry.builtIn.connector(id: .kodbox)?.defaultEndpoint ?? "https://example.com/index.php/dav/"
    @State private var remoteUsername = ""
    @State private var remotePassword = ""
    @State private var allowInsecureHTTP = false
    @State private var pluginSearchText = ""
    @State private var pluginSecretDrafts: [String: String] = [:]
    @State private var configuringPlugin: LoadedPlugin?

    var body: some View {
        NavigationSplitView {
            settingsSidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            settingsDetail
        }
        .frame(width: 920, height: 620)
        .sheet(item: $configuringPlugin) { plugin in
            PluginConfigurationView(
                plugin: plugin,
                pluginSecretDrafts: $pluginSecretDrafts,
                onDone: { configuringPlugin = nil }
            )
        }
    }

    private var settingsSidebar: some View {
        List(selection: $selectedSettingsSection) {
            Section("Settings") {
                ForEach(SettingsSection.primarySections) { section in
                    SettingsSidebarRow(section: section)
                        .tag(section)
                }
            }

            Section("Connections") {
                SettingsSidebarRow(section: .connections)
                    .tag(SettingsSection.connections)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch selectedSettingsSection ?? .general {
        case .general:
            GeneralSettingsView()
        case .plugins:
            PluginSettingsView(
                pluginSearchText: $pluginSearchText,
                configuringPlugin: $configuringPlugin
            )
        case .connections:
            ConnectionsSettingsView(
                selectedConnectorID: $selectedConnectorID,
                remoteName: $remoteName,
                remoteEndpoint: $remoteEndpoint,
                remoteUsername: $remoteUsername,
                remotePassword: $remotePassword,
                allowInsecureHTTP: $allowInsecureHTTP
            )
        }
    }
}
