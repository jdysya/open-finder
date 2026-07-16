import OpenFinderCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
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

struct SettingsSidebarRow: View {
    let section: SettingsSection

    var body: some View {
        Label(section.title, systemImage: section.systemImage)
            .labelStyle(.titleAndIcon)
    }
}

struct PluginListRow: View {
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

            Button(action: onConfigure) {
                Label("Configure", systemImage: "gearshape")
            }

            Button(action: onReveal) {
                Label("Reveal", systemImage: "folder")
            }
        }
        .padding(.vertical, 11)
    }
}

func settingsPage<Content: View>(
    title: String,
    subtitle: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
) -> some View {
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

func settingsCard<Content: View>(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Label(title, systemImage: systemImage)
            .font(.headline)
        content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 12))
}

extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith nilValue: String) {
        self.init(
            get: { source.wrappedValue ?? nilValue },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
