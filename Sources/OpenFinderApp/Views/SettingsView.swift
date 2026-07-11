import AppKit
import OpenFinderCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
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
            pluginConfigurationDialog(plugin)
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
            generalSettingsPage
        case .plugins:
            pluginSettingsPage
        case .connections:
            connectionsSettingsPage
        }
    }

    private var generalSettingsPage: some View {
        settingsPage(title: "General", subtitle: "Application behavior and runtime paths.", systemImage: "gearshape") {
            settingsCard(title: "Behavior", systemImage: "switch.2") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show hidden files by default", isOn: $app.configuration.defaultShowHiddenFiles)
                    Toggle("Confirm before permanent delete", isOn: $app.configuration.confirmBeforePermanentDelete)
                    Stepper("Max concurrent tasks: \(app.configuration.maxConcurrentTasks)", value: $app.configuration.maxConcurrentTasks, in: 1...8)
                }
            }

            settingsCard(title: "Runtime Paths", systemImage: "terminal") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Python 3")
                            .foregroundStyle(.secondary)
                        TextField("Use system python3", text: Binding($app.configuration.python3Path, replacingNilWith: ""))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                    }
                    GridRow {
                        Text("Node")
                            .foregroundStyle(.secondary)
                        TextField("Use system node", text: Binding($app.configuration.nodePath, replacingNilWith: ""))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var pluginSettingsPage: some View {
        settingsPage(title: "Plugins", subtitle: "Installed plugin actions appear in file context menus when their selection rules match.", systemImage: "puzzlepiece.extension") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search installed plugins…", text: $pluginSearchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator.opacity(0.65), lineWidth: 1)
                    }

                    Button {
                        app.loadPlugins()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }

                    Button {
                        openApplicationPluginsFolder()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                }

                settingsCard(title: "Installed Plugins", systemImage: "list.bullet.rectangle") {
                    if app.loadedPlugins.isEmpty {
                        ContentUnavailableView(
                            "No Plugins Loaded",
                            systemImage: "puzzlepiece.extension",
                            description: Text("Install plugins, then rescan this page.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else if filteredPlugins.isEmpty {
                        ContentUnavailableView.search(text: pluginSearchText)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredPlugins.enumerated()), id: \.element.id) { index, plugin in
                                PluginListRow(
                                    plugin: plugin,
                                    configurationSummary: pluginConfigurationSummary(plugin),
                                    onConfigure: { configuringPlugin = plugin },
                                    onReveal: { revealPluginDirectory(plugin) }
                                )
                                if index < filteredPlugins.count - 1 {
                                    Divider()
                                        .padding(.leading, 46)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var connectionsSettingsPage: some View {
        settingsPage(title: "Connections", subtitle: "Add remote accounts and open them in the active pane.", systemImage: "externaldrive.connected.to.line.below") {
            settingsCard(title: "Add Account", systemImage: "plus.circle") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Connector")
                            .foregroundStyle(.secondary)
                        Picker("Connector", selection: $selectedConnectorID) {
                            ForEach(app.remoteConnectors) { connector in
                                Text(connector.displayName).tag(connector.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240, alignment: .leading)
                        .onChange(of: selectedConnectorID) { _, connectorID in
                            if let connector = app.remoteConnectors.first(where: { $0.id == connectorID }) {
                                remoteEndpoint = connector.defaultEndpoint
                            }
                        }
                    }
                    GridRow {
                        Text("Display name")
                            .foregroundStyle(.secondary)
                        TextField("My Remote", text: $remoteName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                    }
                    GridRow {
                        Text("Endpoint")
                            .foregroundStyle(.secondary)
                        TextField(currentConnector?.endpointHint ?? "Remote endpoint URL", text: $remoteEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                    }
                    GridRow {
                        Text("Username")
                            .foregroundStyle(.secondary)
                        TextField("Username", text: $remoteUsername)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                    }
                    GridRow {
                        Text("Password / token")
                            .foregroundStyle(.secondary)
                        SecureField("Password / token", text: $remotePassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                    }
                }
                .font(.callout)

                Toggle("Allow insecure HTTP for local development", isOn: $allowInsecureHTTP)

                Button("Add Account") {
                    app.addRemoteAccount(
                        connectorID: selectedConnectorID,
                        name: remoteName,
                        endpoint: remoteEndpoint,
                        username: remoteUsername,
                        password: remotePassword,
                        allowInsecureHTTP: allowInsecureHTTP
                    )
                    remotePassword = ""
                }
            }

            settingsCard(title: "Accounts", systemImage: "externaldrive") {
                if app.remoteAccounts.isEmpty {
                    Text("No remote accounts configured.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(app.remoteAccounts.enumerated()), id: \.element.id) { index, account in
                            HStack(spacing: 12) {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.name)
                                        .font(.headline)
                                    Text(account.baseURL?.absoluteString ?? "No URL")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("Open") { app.openRemoteAccountInActivePane(account) }
                                Button("Remove", role: .destructive) { app.removeRemoteAccount(account) }
                            }
                            .padding(.vertical, 9)
                            if index < app.remoteAccounts.count - 1 {
                                Divider()
                                    .padding(.leading, 36)
                            }
                        }
                    }
                }
            }
        }
    }

    private func settingsPage<Content: View>(title: String, subtitle: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title2.weight(.semibold))
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                content()
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(.regularMaterial)
    }

    private func settingsCard<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var filteredPlugins: [LoadedPlugin] {
        let query = pluginSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return app.loadedPlugins }
        return app.loadedPlugins.filter { plugin in
            plugin.manifest.name.localizedCaseInsensitiveContains(query)
                || plugin.manifest.id.localizedCaseInsensitiveContains(query)
                || (plugin.manifest.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var currentConnector: RemoteConnector? {
        app.remoteConnectors.first { $0.id == selectedConnectorID }
    }

    private func pluginConfigurationSummary(_ plugin: LoadedPlugin) -> String {
        let count = plugin.manifest.configuration.count + plugin.manifest.permissions.keychainSecrets.count
        return count == 0 ? "No configuration" : "\(count) configurable item\(count == 1 ? "" : "s")"
    }

    private func openApplicationPluginsFolder() {
        let url = AppModel.applicationSupportDirectory().appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func revealPluginDirectory(_ plugin: LoadedPlugin) {
        NSWorkspace.shared.activateFileViewerSelecting([plugin.directory])
    }

    private func pluginConfigurationDialog(_ plugin: LoadedPlugin) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.manifest.name)
                        .font(.title3.weight(.semibold))
                    Text(plugin.manifest.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let description = plugin.manifest.description {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("v\(plugin.manifest.version)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                Button("Done") { configuringPlugin = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    settingsCard(title: "Configuration", systemImage: "slider.horizontal.3") {
                        pluginConfigurationSection(plugin)
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
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(plugin.directory.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer()
                            Button("Reveal") { revealPluginDirectory(plugin) }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 680, height: 620)
    }

    @ViewBuilder
    private func pluginConfigurationSection(_ plugin: LoadedPlugin) -> some View {
        if plugin.manifest.configuration.isEmpty && plugin.manifest.permissions.keychainSecrets.isEmpty {
            Text("No configurable parameters for this plugin.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                ForEach(plugin.manifest.configuration, id: \.key) { field in
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.title)
                            if field.required {
                                Text("Required")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
            .font(.callout)
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
            .frame(maxWidth: 320)
        } else if field.type == "bool" || field.type == "boolean" {
            Toggle("", isOn: Binding(
                get: { pluginConfigBinding(plugin: plugin, field: field).wrappedValue == "true" },
                set: { pluginConfigBinding(plugin: plugin, field: field).wrappedValue = $0 ? "true" : "false" }
            ))
            .labelsHidden()
        } else {
            TextField(field.defaultValue ?? "", text: pluginConfigBinding(plugin: plugin, field: field))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
        }
    }

    private func pluginSecretControl(plugin: LoadedPlugin, key: String) -> some View {
        HStack {
            SecureField(
                app.pluginSecretConfigured(pluginID: plugin.id, key: key) ? "Configured" : "Not configured",
                text: pluginSecretDraftBinding(pluginID: plugin.id, key: key)
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 250)
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

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case plugins
    case connections

    static let primarySections: [SettingsSection] = [.general, .plugins]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .plugins: "Plugins"
        case .connections: "Connections"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .plugins: "puzzlepiece.extension"
        case .connections: "externaldrive.connected.to.line.below"
        }
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection

    var body: some View {
        Label(section.title, systemImage: section.systemImage)
            .labelStyle(.titleAndIcon)
    }
}

private struct PluginListRow: View {
    let plugin: LoadedPlugin
    let configurationSummary: String
    let onConfigure: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(plugin.manifest.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("v\(plugin.manifest.version)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if let description = plugin.manifest.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text("\(plugin.manifest.actions.count) action\(plugin.manifest.actions.count == 1 ? "" : "s")")
                    Text(configurationSummary)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 16)

            Button {
                onConfigure()
            } label: {
                Label("Configure", systemImage: "gearshape")
            }

            Button {
                onReveal()
            } label: {
                Label("Reveal", systemImage: "folder")
            }
        }
        .padding(.vertical, 11)
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
