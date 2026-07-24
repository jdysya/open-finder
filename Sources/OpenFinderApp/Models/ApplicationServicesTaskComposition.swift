import OpenFinderCore

extension ApplicationServices {
    static func taskRegistrations(
        pluginResolver: AppPluginTaskResolver,
        credentialResolver: PluginCredentialResolver,
        coordinator: PluginExecutionCoordinator,
        projections: PluginResultProjectionBox,
        fileSources: FileSourceRegistry,
        transferCoordinator: TransferCoordinator
    ) -> [AppDurableHandlerComposition.TaskRegistration] {
        [
            .init(
                handler: PluginExecuteTaskHandler(
                    pluginResolver: PluginTaskPluginResolver { pluginID, pluginVersion in
                        try await pluginResolver.resolve(
                            pluginID: pluginID,
                            pluginVersion: pluginVersion
                        )
                    },
                    credentialResolver: credentialResolver,
                    coordinator: coordinator,
                    publish: { taskID, projection in
                        await projections.store(projection, for: taskID)
                    },
                    cleanupWarning: { events in
                        _ = await events.appendLog(
                            PluginWorkspaceMaintenance.cleanupWarning,
                            level: "warning"
                        )
                    }
                ).taskHandler,
                dependencies: [
                    .pluginResolver,
                    .credentialResolver,
                    .pluginExecutionCoordinator,
                ]
            ),
            .init(
                handler: TransferCopyTaskHandler(
                    fileSources: fileSources,
                    coordinator: transferCoordinator
                ).taskHandler,
                dependencies: [.fileSourceRegistry, .transferCoordinator]
            ),
            .init(
                handler: TransferMoveTaskHandler(
                    fileSources: fileSources,
                    coordinator: transferCoordinator
                ).taskHandler,
                dependencies: [.fileSourceRegistry, .transferCoordinator]
            ),
        ]
    }
}
