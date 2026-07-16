import AppKit
import OpenFinderCore
import SwiftUI

struct PluginConfigurationView: View {
    @EnvironmentObject private var app: AppModel
    let plugin: LoadedPlugin
    @Binding var pluginSecretDrafts: [String: String]
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 680, height: 620)
    }

    private var header: some View {
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
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsCard(title: "Configuration", systemImage: "slider.horizontal.3") {
                    configurationSection
                }

                if case .http = plugin.manifest.execution {
                    PluginConnectionDiagnosticsView(plugin: plugin)
                }

                settingsCard(title: "Actions", systemImage: "cursorarrow.click") {
                    actionsSection
                }

                settingsCard(title: "Permissions", systemImage: "lock.shield") {
                    permissionsSection
                }

                settingsCard(title: "Location", systemImage: "folder") {
                    locationSection
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var configurationSection: some View {
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
                        pluginConfigControl(field: field)
                    }
                }
                ForEach(plugin.manifest.permissions.keychainSecrets, id: \.self) { key in
                    GridRow {
                        Text(key)
                        pluginSecretControl(key: key)
                    }
                }
            }
            .font(.callout)
        }
    }

    private var actionsSection: some View {
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
                    Text(pluginSelectionSummary(action.selection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(pluginMatchSummary(action.match))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if action.id != plugin.manifest.actions.last?.id {
                    Divider()
                }
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pluginPermissionRows(plugin.manifest.permissions), id: \.self) { row in
                Label(row, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var locationSection: some View {
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

    @ViewBuilder
    private func pluginConfigControl(field: PluginConfigField) -> some View {
        if let options = field.options, !options.isEmpty {
            Picker(field.title, selection: pluginConfigBinding(field: field)) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
        } else if field.type == "bool" || field.type == "boolean" {
            Toggle("", isOn: Binding(
                get: { pluginConfigBinding(field: field).wrappedValue == "true" },
                set: { pluginConfigBinding(field: field).wrappedValue = $0 ? "true" : "false" }
            ))
            .labelsHidden()
        } else {
            TextField(field.defaultValue ?? "", text: pluginConfigBinding(field: field))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
        }
    }

    private func pluginSecretControl(key: String) -> some View {
        HStack {
            SecureField(
                app.pluginSecretConfigured(pluginID: plugin.id, key: key) ? "Configured" : "Not configured",
                text: pluginSecretDraftBinding(key: key)
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 250)
            Button("Save") {
                app.setPluginSecret(pluginSecretDrafts[pluginSecretDraftKey(key: key)] ?? "", pluginID: plugin.id, key: key)
                pluginSecretDrafts[pluginSecretDraftKey(key: key)] = ""
            }
            Button("Clear") {
                app.setPluginSecret("", pluginID: plugin.id, key: key)
                pluginSecretDrafts[pluginSecretDraftKey(key: key)] = ""
            }
        }
    }

    private func pluginConfigBinding(field: PluginConfigField) -> Binding<String> {
        Binding(
            get: {
                let value = app.pluginConfigValue(pluginID: plugin.id, key: field.key)
                return value.isEmpty ? field.defaultValue ?? "" : value
            },
            set: { app.setPluginConfigValue($0, pluginID: plugin.id, key: field.key) }
        )
    }

    private func pluginSecretDraftBinding(key: String) -> Binding<String> {
        let draftKey = pluginSecretDraftKey(key: key)
        return Binding(
            get: { pluginSecretDrafts[draftKey] ?? "" },
            set: { pluginSecretDrafts[draftKey] = $0 }
        )
    }

    private func pluginSecretDraftKey(key: String) -> String {
        "\(plugin.id).\(key)"
    }
}
