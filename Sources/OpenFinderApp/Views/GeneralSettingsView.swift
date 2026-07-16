import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        settingsPage(
            title: "General",
            subtitle: "Application behavior and runtime paths.",
            systemImage: "gearshape"
        ) {
            settingsCard(title: "Behavior", systemImage: "switch.2") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show hidden files by default", isOn: $app.configuration.defaultShowHiddenFiles)
                    Toggle("Confirm before permanent delete", isOn: $app.configuration.confirmBeforePermanentDelete)
                    Stepper(
                        "Max concurrent tasks: \(app.configuration.maxConcurrentTasks)",
                        value: $app.configuration.maxConcurrentTasks,
                        in: 1...8
                    )
                }
            }

            settingsCard(title: "Runtime Paths", systemImage: "terminal") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Python 3")
                            .foregroundStyle(.secondary)
                        TextField(
                            "Use system python3",
                            text: Binding($app.configuration.python3Path, replacingNilWith: "")
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                    }
                    GridRow {
                        Text("Node")
                            .foregroundStyle(.secondary)
                        TextField(
                            "Use system node",
                            text: Binding($app.configuration.nodePath, replacingNilWith: "")
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                    }
                }
                .font(.callout)
            }
        }
    }
}
