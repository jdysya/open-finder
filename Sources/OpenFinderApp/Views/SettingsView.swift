import OpenFinderCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var webDAVName = ""
    @State private var webDAVBaseURL = "https://example.com/dav/"
    @State private var webDAVUsername = ""
    @State private var webDAVPassword = ""
    @State private var allowInsecureHTTP = false

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

            VStack(alignment: .leading) {
                HStack {
                    Text("Loaded Plugins")
                        .font(.headline)
                    Spacer()
                    Button("Rescan") { app.loadPlugins() }
                }
                List(app.loadedPlugins) { plugin in
                    VStack(alignment: .leading) {
                        Text(plugin.manifest.name)
                        Text(plugin.manifest.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(plugin.directory.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
}

private extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith nilValue: String) {
        self.init(
            get: { source.wrappedValue ?? nilValue },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
