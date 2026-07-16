import OpenFinderCore
import SwiftUI

struct ConnectionsSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Binding var selectedConnectorID: RemoteConnectorID
    @Binding var remoteName: String
    @Binding var remoteEndpoint: String
    @Binding var remoteUsername: String
    @Binding var remotePassword: String
    @Binding var allowInsecureHTTP: Bool

    var body: some View {
        settingsPage(
            title: "Connections",
            subtitle: "Add remote accounts and open them in the active pane.",
            systemImage: "externaldrive.connected.to.line.below"
        ) {
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

    private var currentConnector: RemoteConnector? {
        app.remoteConnectors.first { $0.id == selectedConnectorID }
    }
}
