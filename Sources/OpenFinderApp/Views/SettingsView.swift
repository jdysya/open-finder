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
    @State private var selectedPluginID: String?

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

            pluginSettingsTab
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
        .frame(width: 760, height: 520)
    }

    private var selectedPlugin: LoadedPlugin? {
        if let selectedPluginID, let plugin = app.loadedPlugins.first(where: { $0.id == selectedPluginID }) {
            return plugin
        }
        return app.loadedPlugins.first
    }

    private var pluginSettingsTab: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plugins")
                        .font(.headline)
                    Text("Configure global plugin parameters here; matching actions appear in the file context menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rescan") {
                    app.loadPlugins()
                    selectFirstPluginIfNeeded()
                }
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 8)

            NavigationSplitView {
                List(selection: $selectedPluginID) {
                    ForEach(app.loadedPlugins) { plugin in
                        PluginListRow(plugin: plugin)
                            .tag(plugin.id)
                    }
                }
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            } detail: {
                if let plugin = selectedPlugin {
                    pluginDetail(plugin)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No Plugins Loaded")
                            .font(.headline)
                        Text("Install or rescan plugins to configure them.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { selectFirstPluginIfNeeded() }
        .onChange(of: app.loadedPlugins) { _, _ in selectFirstPluginIfNeeded() }
    }

    private func selectFirstPluginIfNeeded() {
        guard selectedPluginID == nil || !app.loadedPlugins.contains(where: { $0.id == selectedPluginID }) else { return }
        selectedPluginID = app.loadedPlugins.first?.id
    }

    private func pluginDetail(_ plugin: LoadedPlugin) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.manifest.name)
                            .font(.title3.weight(.semibold))
                        Text(plugin.manifest.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let description = plugin.manifest.description {
                            Text(description)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("v\(plugin.manifest.version)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }

                settingsCard(title: "Actions", systemImage: "cursorarrow.click") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(plugin.manifest.actions) { action in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(action.title)
                                        .font(.headline)
                                    Spacer()
                                    if let category = action.category {
                                        Text(category)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text(selectionSummary(action.selection))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(matchSummary(action.match))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if action.id != plugin.manifest.actions.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                settingsCard(title: "Configuration", systemImage: "slider.horizontal.3") {
                    pluginConfigurationSection(plugin)
                }

                settingsCard(title: "Permissions", systemImage: "lock.shield") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(permissionRows(plugin.manifest.permissions), id: \.self) { row in
                            Label(row, systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                settingsCard(title: "Location", systemImage: "folder") {
                    Text(plugin.directory.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(.regularMaterial)
    }

    private func settingsCard<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func pluginConfigurationSection(_ plugin: LoadedPlugin) -> some View {
        if plugin.manifest.configuration.isEmpty && plugin.manifest.permissions.keychainSecrets.isEmpty {
            Text("No configurable parameters for this plugin.")
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

    private func selectionSummary(_ rule: PluginSelectionRule) -> String {
        let count: String
        if let maxItems = rule.maxItems, maxItems == rule.minItems {
            count = "\(rule.minItems) item(s)"
        } else if let maxItems = rule.maxItems {
            count = "\(rule.minItems)-\(maxItems) item(s)"
        } else {
            count = "\(rule.minItems)+ item(s)"
        }
        return rule.allowDirectories ? "Selection: \(count), files or folders" : "Selection: \(count), files only"
    }

    private func matchSummary(_ match: PluginMatchRule?) -> String {
        guard let match else { return "Appears for any matching selection count." }
        var parts: [String] = []
        if !match.extensions.isEmpty {
            parts.append("extensions: " + match.extensions.map { ".\($0)" }.joined(separator: ", "))
        }
        if !match.uttypes.isEmpty {
            parts.append("types: " + match.uttypes.joined(separator: ", "))
        }
        if !match.mimePrefixes.isEmpty {
            parts.append("MIME: " + match.mimePrefixes.joined(separator: ", "))
        }
        return parts.isEmpty ? "No file-type restrictions." : "Appears for \(parts.joined(separator: "; "))."
    }

    private func permissionRows(_ permissions: PluginPermissions) -> [String] {
        var rows = [
            "Read files: \(permissions.readFiles)",
            "Write files: \(permissions.writeFiles)"
        ]
        if permissions.runExternalCommands { rows.append("Can run external commands") }
        if permissions.clipboardRead { rows.append("Can read clipboard") }
        if permissions.clipboardWrite { rows.append("Can write clipboard") }
        if permissions.network.required {
            rows.append("Network: \(permissions.network.hosts.isEmpty ? "allowed" : permissions.network.hosts.joined(separator: ", "))")
        }
        if !permissions.keychainSecrets.isEmpty {
            rows.append("Keychain secrets: \(permissions.keychainSecrets.joined(separator: ", "))")
        }
        if permissions.remoteAccounts { rows.append("Can access configured remote accounts") }
        return rows
    }
}

private struct PluginListRow: View {
    let plugin: LoadedPlugin

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.manifest.name)
                    .lineLimit(1)
                Text("\(plugin.manifest.actions.count) action(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
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
