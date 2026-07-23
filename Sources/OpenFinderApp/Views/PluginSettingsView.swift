import AppKit
import OpenFinderCore
import SwiftUI

struct PluginSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Binding var pluginSearchText: String
    @Binding var configuringPlugin: LoadedPlugin?

    var body: some View {
        settingsPage(
            title: "Plugins",
            subtitle: "Installed plugin actions appear in file context menus when their selection rules match.",
            systemImage: "puzzlepiece.extension"
        ) {
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

                if !app.pluginLoadDiagnostics.isEmpty {
                    settingsCard(title: "Plugin Diagnostics", systemImage: "exclamationmark.triangle") {
                        VStack(spacing: 0) {
                            ForEach(Array(app.pluginLoadDiagnostics.enumerated()), id: \.element.id) { index, diagnostic in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "xmark.octagon.fill")
                                        .foregroundStyle(.red)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(diagnostic.pluginDirectory.lastPathComponent)
                                            .font(.body.weight(.medium))
                                        Text(diagnostic.message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                        Text("\(diagnostic.source.displayName) · \(diagnostic.pluginDirectory.path)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                    Button("Reveal") {
                                        NSWorkspace.shared.activateFileViewerSelecting([diagnostic.pluginDirectory])
                                    }
                                    .buttonStyle(.link)
                                }
                                .padding(.vertical, 10)
                                if index < app.pluginLoadDiagnostics.count - 1 {
                                    Divider()
                                        .padding(.leading, 34)
                                }
                            }
                        }
                    }
                }
            }
        }
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

    private func pluginConfigurationSummary(_ plugin: LoadedPlugin) -> String {
        let count = plugin.manifest.configuration.count + plugin.manifest.permissions.secretKeys.count
        return count == 0 ? "No configuration" : "\(count) configurable item\(count == 1 ? "" : "s")"
    }

    private func openApplicationPluginsFolder() {
        let url = AppModel.applicationSupportDirectory().appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
