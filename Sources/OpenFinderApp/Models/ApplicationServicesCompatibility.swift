import Foundation
import OpenFinderCore

@MainActor
extension AppModel {
    convenience init(
        remoteDirectory: RemoteAccountDirectory? = nil,
        configurationStore: (any AppConfigurationStore)? = nil,
        keychainStore: (any KeychainStore)? = nil,
        localPluginCredentialStore: LocalPluginCredentialStore? = nil,
        remoteConnectorRegistry: RemoteConnectorRegistry = .builtIn,
        remoteProviderRegistry: RemoteProviderRegistry? = nil,
        taskQueue: TaskQueueService? = nil,
        taskDatabaseURL: URL? = nil,
        pluginRunnerRouter: PluginRunnerRouter? = nil,
        pluginConnectionChecker: (any PluginConnectionChecking)? = nil,
        pluginWorkspaceMaintenance: PluginWorkspaceMaintenance = .live(),
        artifactResultService: ArtifactResultService? = nil,
        pluginResultHandlers: [PluginResultHandler] = [
            PluginResultHandlerRegistry.mediaAnalysis
        ],
        pluginRendererEntries: [PluginRendererCatalog.Entry] = [.mediaAnalysis],
        startAutomatically: Bool = true
    ) {
        self.init(
            services: ApplicationServices(dependencies: .init(
                remoteDirectory: remoteDirectory,
                configurationStore: configurationStore,
                keychainStore: keychainStore,
                localPluginCredentialStore: localPluginCredentialStore,
                remoteConnectorRegistry: remoteConnectorRegistry,
                remoteProviderRegistry: remoteProviderRegistry,
                taskQueue: taskQueue,
                taskDatabaseURL: taskDatabaseURL,
                pluginRunnerRouter: pluginRunnerRouter,
                pluginConnectionChecker: pluginConnectionChecker,
                pluginWorkspaceMaintenance: pluginWorkspaceMaintenance,
                artifactResultService: artifactResultService,
                pluginResultHandlers: pluginResultHandlers,
                pluginRendererEntries: pluginRendererEntries
            )),
            startAutomatically: startAutomatically
        )
    }
}
