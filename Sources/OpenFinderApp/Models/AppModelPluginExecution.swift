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
                let currentLocation = try pane.fileBrowserService.normalizedLocation(
                    pane.location
                )
                let normalizedInputs = try items.map { item in
                    PluginTaskInputSnapshot(
                        location: try pane.fileBrowserService.normalizedLocation(item.location),
                        identity: .init(item)
                    )
                }
                let paneID = pane.id.rawValue
                let configurationValues = configuration.pluginConfigurationValues[plugin.id] ?? [:]
                let secretReferences = configuredPluginSecretReferences(for: plugin.manifest)
                try await requireDurableHandlerReadiness()
                await pluginTaskResolver.register(plugin)
                let taskID = UUID()
                let resultSchemaID = action.output?.resultSchemaID ?? "unknown"
                let envelope = PluginTaskEnvelope(
                    pluginID: plugin.id,
                    pluginVersion: plugin.manifest.version,
                    actionID: action.id,
                    resultSchemaID: resultSchemaID,
                    outputPolicy: .init(
                        canCopyToClipboard: action.output?.canCopyToClipboard ?? false
                    ),
                    app: .init(name: "OpenFinder", version: "0.1.0"),
                    context: .init(
                        activePane: paneID,
                        currentLocation: currentLocation
                    ),
                    inputs: normalizedInputs,
                    configuration: configurationValues,
                    secretReferences: secretReferences,
                    workspacePolicy: .taskScopedTemporary
                )
                let resourceKey = action.output?.resultSchemaID
                    ?? "plugin:\(plugin.id):\(action.id)"
                let descriptor = try envelope.makeDescriptor(
                    taskID: taskID,
                    resourceKey: resourceKey,
                    idempotencyKey: try envelope.idempotencyKey(),
                    lineage: .init(rootTaskID: taskID),
                    queueOrdinal: await taskApplicationService.reserveQueueOrdinal()
                )
                let queuedID = try await taskApplicationService.enqueue(.init(
                    kind: .plugin(pluginID: plugin.id, actionID: action.id),
                    title: "\(plugin.manifest.name): \(action.title)",
                    descriptor: descriptor
                ))
                statusMessage = "Queued plugin task \(queuedID.uuidString.prefix(8))"
                await observeTask(queuedID)
                if let projection = await pluginResultProjections.take(for: queuedID) {
                    presentedPluginResult = projection
                    presentedVideoAnalysis = nil
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func requireDurableHandlerReadiness() async throws {
        do {
            try await taskApplicationService.requireReadiness()
            durableHandlerReadiness = .ready
        } catch {
            durableHandlerReadiness = .unavailable(error.localizedDescription)
            throw error
        }
    }
}
