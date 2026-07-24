import Foundation
import OpenFinderCore

extension AppModel {
    func runPlugin(
        _ plugin: LoadedPlugin,
        action: PluginActionManifest,
        items: [FileItem],
        pane: BrowserPaneModel
    ) {
        Task {
            do {
                if case .http = plugin.manifest.execution {
                    let connection = await checkPluginConnection(plugin)
                    guard connection.canSubmit else {
                        statusMessage = connection.guidance
                        return
                    }
                }
                let currentLocation = pane.location
                let paneID = pane.id.rawValue
                let resultBox = PluginResultProjectionBox()
                let coordinator = pluginExecutionCoordinator
                let configurationValues = configuration.pluginConfigurationValues[plugin.id] ?? [:]
                let secretReferences = configuredPluginSecretReferences(for: plugin.manifest)
                let queuedID = try await taskQueue.enqueue(.init(
                    kind: .plugin(pluginID: plugin.id, actionID: action.id),
                    title: "\(plugin.manifest.name): \(action.title)",
                    resourceKey: action.output?.resultSchemaID
                ) { context in
                    await context.appendLog(
                        "Starting plugin \(plugin.manifest.name) / \(action.title)"
                    )
                    let outcome = try await coordinator.execute(.init(
                        plugin: plugin,
                        pluginVersion: plugin.manifest.version,
                        action: action,
                        taskID: context.id,
                        app: .init(name: "OpenFinder", version: "0.1.0"),
                        context: .init(activePane: paneID, currentLocation: currentLocation),
                        files: items.map(PluginInputFile.init(item:)),
                        configurationValues: configurationValues,
                        secretReferences: secretReferences
                    ), callbacks: .init(
                        onEvent: { event in
                            Task {
                                switch event {
                                case .log(let level, let message):
                                    await context.appendLog(message, level: level)
                                case .progress(let progress):
                                    await context.updateProgress(.init(
                                        fraction: progress.fraction,
                                        phase: progress.phase,
                                        detail: progress.message,
                                        completed: progress.completed,
                                        total: progress.total,
                                        unit: progress.unit
                                    ))
                                case .result(_, let message, _, _):
                                    if let message { await context.appendLog(message) }
                                }
                            }
                        },
                        publish: { projection in
                            await resultBox.store(projection)
                        },
                        cleanupWarning: {
                            await context.appendLog(
                                PluginWorkspaceMaintenance.cleanupWarning,
                                level: "warning"
                            )
                        }
                    ))
                    return .success(summary: outcome.summary, clipboard: outcome.clipboard)
                })
                statusMessage = "Queued plugin task \(queuedID.uuidString.prefix(8))"
                await observeTask(queuedID)
                if let projection = await resultBox.value {
                    presentedPluginResult = projection
                    presentedVideoAnalysis = nil
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

}
