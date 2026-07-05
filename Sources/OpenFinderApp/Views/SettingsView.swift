import OpenFinderCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var webDAVName = ""
    @State private var webDAVBaseURL = "https://example.com/dav/"
    @State private var webDAVUsername = ""
    @State private var webDAVPassword = ""
    @State private var allowInsecureHTTP = false
    @State private var pluginSecretDrafts: [String: String] = [:]

    var body: some View {
        TabView {
            Form {
                Toggle("Show hidden files by default", isOn: $app.configuration.defaultShowHiddenFiles)
                Toggle("Confirm before permanent delete", isOn: $app.configuration.confirmBeforePermanentDelete)
                Stepper("Max concurrent tasks: \(app.configuration.maxConcurrentTasks)", value: $app.configuration.maxConcurrentTasks, in: 1...8)
                TextField("Python 3 path", text: Binding($app.configuration.python3Path, replacingNilWith: ""))
                TextField("Node path", text: Binding($app.configuration.nodePath, replacingNilWith: ""))
            }
            .padding()
            .tabItem { Label("Runtimes", systemImage: "terminal") }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Loaded Plugins")
                        .font(.headline)
                    Spacer()
                    Button("Rescan") { app.loadPlugins() }
                }
                List(app.loadedPlugins) { plugin in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            if let description = plugin.manifest.description {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(plugin.directory.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            pluginConfigurationSection(plugin)
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading) {
                                Text(plugin.manifest.name)
                                Text(plugin.manifest.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding()
            .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }

            VStack(alignment: .leading, spacing: 12) {
                Form {
                    TextField("Display name", text: $webDAVName)
                    TextField("Base URL", text: $webDAVBaseURL)
                    TextField("Username", text: $webDAVUsername)
                    SecureField("Password / token", text: $webDAVPassword)
                    Toggle("Allow insecure HTTP for local development", isOn: $allowInsecureHTTP)
                    Button("Add WebDAV Account") {
                        app.addWebDAVAccount(
                            name: webDAVName,
                            baseURL: webDAVBaseURL,
                            username: webDAVUsername,
                            password: webDAVPassword,
                            allowInsecureHTTP: allowInsecureHTTP
                        )
                        webDAVPassword = ""
                    }
                }
                Divider()
                Text("Accounts")
                    .font(.headline)
                List(app.webDAVAccounts) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.name)
                            Text(account.baseURL?.absoluteString ?? "No URL")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { app.openWebDAVAccountInActivePane(account) }
                        Button("Remove", role: .destructive) { app.removeWebDAVAccount(account) }
                    }
                }
            }
            .padding()
            .tabItem { Label("WebDAV", systemImage: "externaldrive.connected.to.line.below") }
        }
        .frame(width: 640, height: 460)
    }

    @ViewBuilder
    private func pluginConfigurationSection(_ plugin: LoadedPlugin) -> some View {
        if plugin.manifest.configuration.isEmpty && plugin.manifest.permissions.keychainSecrets.isEmpty {
            Text("No configurable parameters. Matching actions appear in the file context menu when a selection supports them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(plugin.manifest.configuration, id: \.key) { field in
                    GridRow {
                        Text(field.title)
                        pluginConfigControl(plugin: plugin, field: field)
                    }
                }
                ForEach(plugin.manifest.permissions.keychainSecrets, id: \.self) { key in
                    GridRow {
                        Text(key)
                        pluginSecretControl(plugin: plugin, key: key)
                    }
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func pluginConfigControl(plugin: LoadedPlugin, field: PluginConfigField) -> some View {
        if let options = field.options, !options.isEmpty {
            Picker(field.title, selection: pluginConfigBinding(plugin: plugin, field: field)) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
        } else if field.type == "bool" || field.type == "boolean" {
            Toggle("", isOn: Binding(
                get: { pluginConfigBinding(plugin: plugin, field: field).wrappedValue == "true" },
                set: { pluginConfigBinding(plugin: plugin, field: field).wrappedValue = $0 ? "true" : "false" }
            ))
            .labelsHidden()
        } else {
            TextField(field.defaultValue ?? "", text: pluginConfigBinding(plugin: plugin, field: field))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
        }
    }

    private func pluginSecretControl(plugin: LoadedPlugin, key: String) -> some View {
        HStack {
            SecureField(
                app.pluginSecretConfigured(pluginID: plugin.id, key: key) ? "Configured" : "Not configured",
                text: pluginSecretDraftBinding(pluginID: plugin.id, key: key)
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)
            Button("Save") {
                app.setPluginSecret(pluginSecretDrafts[pluginSecretDraftKey(pluginID: plugin.id, key: key)] ?? "", pluginID: plugin.id, key: key)
                pluginSecretDrafts[pluginSecretDraftKey(pluginID: plugin.id, key: key)] = ""
            }
            Button("Clear") {
                app.setPluginSecret("", pluginID: plugin.id, key: key)
                pluginSecretDrafts[pluginSecretDraftKey(pluginID: plugin.id, key: key)] = ""
            }
        }
    }

    private func pluginConfigBinding(plugin: LoadedPlugin, field: PluginConfigField) -> Binding<String> {
        Binding(
            get: {
                let value = app.pluginConfigValue(pluginID: plugin.id, key: field.key)
                return value.isEmpty ? field.defaultValue ?? "" : value
            },
            set: { app.setPluginConfigValue($0, pluginID: plugin.id, key: field.key) }
        )
    }

    private func pluginSecretDraftBinding(pluginID: String, key: String) -> Binding<String> {
        let draftKey = pluginSecretDraftKey(pluginID: pluginID, key: key)
        return Binding(
            get: { pluginSecretDrafts[draftKey] ?? "" },
            set: { pluginSecretDrafts[draftKey] = $0 }
        )
    }

    private func pluginSecretDraftKey(pluginID: String, key: String) -> String {
        "\(pluginID).\(key)"
    }
}

private extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith nilValue: String) {
        self.init(
            get: { source.wrappedValue ?? nilValue },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
