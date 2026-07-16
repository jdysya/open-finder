import OpenFinderCore
import SwiftUI

struct PluginConnectionDiagnosticsView: View {
    @EnvironmentObject private var app: AppModel
    let plugin: LoadedPlugin

    private var status: PluginConnectionStatus? {
        app.pluginConnectionStatus(for: plugin)
    }

    private var presentation: PluginConnectionDiagnosticsState {
        .init(status: status)
    }

    var body: some View {
        Form {
            Section("Local Service") {
                HStack {
                    Label(presentation.title, systemImage: presentation.systemImage)
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("plugin-connection-status")
                    if status?.state == .connecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    Button("Test Connection") {
                        Task { await app.checkPluginConnection(plugin) }
                    }
                    .disabled(!presentation.isTestButtonEnabled)
                    .accessibilityIdentifier("test-plugin-connection")
                }

                if let status {
                    if let protocolVersion = status.protocolVersion {
                        detailRow("Protocol", "v\(protocolVersion)")
                    }
                    if let pluginVersion = status.pluginVersion {
                        detailRow("Plugin", pluginVersion)
                    }
                    if let runtime = status.runtime {
                        detailRow("Runtime", "\(runtime.name) \(runtime.version)")
                    }
                    ForEach(status.checks) { check in
                        checkRow(check)
                    }
                    if !status.guidance.isEmpty {
                        Text(status.guidance)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("plugin-connection-guidance")
                    }
                } else {
                    Text("Test the configured loopback service before running this plugin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
            .font(.callout)
    }

    private func checkRow(_ check: PluginConnectionCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: checkSymbol(check.status))
                .foregroundStyle(checkColor(check.status))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.message)
                    .font(.callout)
                if let remediation = check.remediation, !remediation.isEmpty {
                    Text(remediation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plugin-check-\(check.id)")
    }

    private var statusColor: Color {
        switch status?.state {
        case .ready: .green
        case .degraded: .orange
        case .unavailable: .red
        case .connecting, nil: .secondary
        }
    }

    private func checkSymbol(_ value: String) -> String {
        switch value.lowercased() {
        case "ok", "ready", "pass": "checkmark.circle.fill"
        case "warning", "degraded": "exclamationmark.triangle.fill"
        default: "xmark.circle.fill"
        }
    }

    private func checkColor(_ value: String) -> Color {
        switch value.lowercased() {
        case "ok", "ready", "pass": .green
        case "warning", "degraded": .orange
        default: .red
        }
    }
}
