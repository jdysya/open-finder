import Foundation
import OpenFinderCore

@MainActor
extension ApplicationServices {
    func submitPlugin(
        _ plugin: LoadedPlugin,
        action: PluginActionManifest,
        items: [FileItem],
        pane: BrowserPaneModel,
        configuration: AppConfiguration
    ) async throws -> UUID {
        let currentLocation = try normalizedLocation(pane.location)
        let normalizedInputs = try items.map { item in
            PluginTaskInputSnapshot(
                location: try normalizedLocation(item.location),
                identity: .init(item)
            )
        }
        try await taskService.requireReadiness()
        await pluginResolver.register(plugin)
        let secretReferences = configuredPluginSecretReferences(for: plugin.manifest)
        let resolvedConfiguration = PluginConfigurationResolver.resolve(
            manifest: plugin.manifest,
            values: configuration.pluginConfigurationValues[plugin.id] ?? [:],
            secretReferences: secretReferences
        )
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
                activePane: pane.id.rawValue,
                currentLocation: currentLocation
            ),
            inputs: normalizedInputs,
            configuration: resolvedConfiguration.config,
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
            queueOrdinal: await taskService.reserveQueueOrdinal()
        )
        return try await taskService.enqueue(.init(
            kind: .plugin(pluginID: plugin.id, actionID: action.id),
            title: "\(plugin.manifest.name): \(action.title)",
            descriptor: descriptor
        ))
    }

    func takePluginResult(for taskID: UUID) async -> PluginResultProjection? {
        await resultProjections.take(for: taskID)
    }
}
