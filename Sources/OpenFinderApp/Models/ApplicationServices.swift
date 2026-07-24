import Foundation
import OpenFinderCore

struct ApplicationServiceDependencies {
    var supportDirectory: URL
    var remoteDirectory: RemoteAccountDirectory?
    var configurationStore: (any AppConfigurationStore)?
    var keychainStore: (any KeychainStore)?
    var localPluginCredentialStore: LocalPluginCredentialStore?
    var remoteConnectorRegistry: RemoteConnectorRegistry
    var remoteProviderRegistry: RemoteProviderRegistry?
    var taskQueue: TaskQueueService?
    var taskDatabaseURL: URL?
    var pluginRunnerRouter: PluginRunnerRouter?
    var pluginConnectionChecker: (any PluginConnectionChecking)?
    var pluginWorkspaceMaintenance: PluginWorkspaceMaintenance
    var artifactResultService: ArtifactResultService?
    var pluginResultHandlers: [PluginResultHandler]
    var pluginRendererEntries: [PluginRendererCatalog.Entry]

    init(
        supportDirectory: URL = ApplicationServices.applicationSupportDirectory(),
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
        pluginRendererEntries: [PluginRendererCatalog.Entry] = [.mediaAnalysis]
    ) {
        self.supportDirectory = supportDirectory
        self.remoteDirectory = remoteDirectory
        self.configurationStore = configurationStore
        self.keychainStore = keychainStore
        self.localPluginCredentialStore = localPluginCredentialStore
        self.remoteConnectorRegistry = remoteConnectorRegistry
        self.remoteProviderRegistry = remoteProviderRegistry
        self.taskQueue = taskQueue
        self.taskDatabaseURL = taskDatabaseURL
        self.pluginRunnerRouter = pluginRunnerRouter
        self.pluginConnectionChecker = pluginConnectionChecker
        self.pluginWorkspaceMaintenance = pluginWorkspaceMaintenance
        self.artifactResultService = artifactResultService
        self.pluginResultHandlers = pluginResultHandlers
        self.pluginRendererEntries = pluginRendererEntries
    }
}

@MainActor
final class ApplicationServices {
    let taskService: TaskApplicationService
    let accountService: RemoteAccountService
    let browserService: FileBrowserService
    let configurationService: RuntimeConfigurationService
    let pluginService: PluginManagementService
    let rendererCatalog: PluginRendererCatalog

    private let executionCoordinator: PluginExecutionCoordinator
    let artifactResults: ArtifactResultService?
    let pluginResolver: AppPluginTaskResolver
    let resultProjections: PluginResultProjectionBox
    let recoveryStore: (any TaskStore)?
    let databaseOpenError: (any Error)?
    let compositionResult: Result<AppDurableHandlerComposition, any Error>
    let fileSources: FileSourceRegistry

    init(dependencies: ApplicationServiceDependencies = .init()) {
        let remoteDirectory = dependencies.remoteDirectory ?? RemoteAccountDirectory(
            storageURL: dependencies.supportDirectory.appendingPathComponent("remote-accounts.json")
        )
        let configurationStore = dependencies.configurationStore ?? JSONConfigStore(
            url: dependencies.supportDirectory.appendingPathComponent("config.json")
        )
        let keychainStore = dependencies.keychainStore ?? MacKeychainStore()
        let localCredentialStore = dependencies.localPluginCredentialStore
            ?? LocalPluginCredentialStore()

        var openedTaskStore: (any TaskStore)?
        var taskDatabaseOpenError: (any Error)?
        if let taskDatabaseURL = dependencies.taskDatabaseURL {
            do {
                try FileManager.default.createDirectory(
                    at: taskDatabaseURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                openedTaskStore = GRDBTaskStore(
                    database: try AppDatabase(url: taskDatabaseURL),
                    mode: .durable
                )
            } catch {
                taskDatabaseOpenError = error
            }
        }
        recoveryStore = openedTaskStore
        databaseOpenError = taskDatabaseOpenError

        let queue = dependencies.taskQueue ?? TaskQueueService(
            maxConcurrentTasks: 2,
            store: openedTaskStore
        )
        let taskService = TaskApplicationService(queue: queue)
        self.taskService = taskService
        let configurationService = RuntimeConfigurationService(
            store: configurationStore,
            taskQueue: queue
        )
        self.configurationService = configurationService
        let pluginService = PluginManagementService(
            configurationService: configurationService,
            keychainStore: keychainStore,
            localCredentialStore: localCredentialStore,
            connectionChecker: dependencies.pluginConnectionChecker
        )
        self.pluginService = pluginService

        let providerRegistry = dependencies.remoteProviderRegistry ?? RemoteProviderRegistry(
            connectorRegistry: dependencies.remoteConnectorRegistry,
            account: { accountID in
                guard let accountID = UUID(uuidString: accountID) else { return nil }
                return remoteDirectory.account(id: accountID)
            },
            credentialStore: pluginService.credentialStore
        )
        let fileSources = FileSourceRegistry(remoteProviderRegistry: providerRegistry)
        self.fileSources = fileSources
        accountService = RemoteAccountService(
            directory: remoteDirectory,
            connectorRegistry: dependencies.remoteConnectorRegistry,
            providerRegistry: providerRegistry,
            keychainStore: keychainStore
        )
        let browserService = FileBrowserService(
            fileSourceRegistry: fileSources,
            taskService: taskService
        )
        self.browserService = browserService

        let configuredRunner: PluginRunnerRouter
        let configurableProcessRunner: ConfigurableProcessPluginRunner?
        if let injectedRunner = dependencies.pluginRunnerRouter {
            configuredRunner = injectedRunner
            configurableProcessRunner = nil
        } else {
            let processRunner = ConfigurableProcessPluginRunner()
            configuredRunner = PluginRunnerRouter(
                processRunner: processRunner,
                httpRunner: HTTPPluginRunner(
                    credentialResolver: pluginService.credentialResolver
                )
            )
            configurableProcessRunner = processRunner
        }
        configurationService.attach(processRunner: configurableProcessRunner)
        executionCoordinator = PluginExecutionCoordinator(
            runner: configuredRunner,
            connectionChecker: pluginService.connectionChecking,
            credentialResolver: pluginService.credentialResolver,
            resultHandlers: (try? PluginResultHandlerRegistry(
                handlers: dependencies.pluginResultHandlers
            )) ?? .standard,
            workspaceMaintenance: .init { workspace in
                try dependencies.pluginWorkspaceMaintenance.cleanup(
                    .init(executionWorkspace: workspace)
                )
            }
        )
        if let injectedArtifactResults = dependencies.artifactResultService {
            artifactResults = injectedArtifactResults
        } else {
            let metadata = InMemoryArtifactMetadataBackend()
            let root = dependencies.supportDirectory.appendingPathComponent(
                "artifacts",
                isDirectory: true
            )
            artifactResults = try? ArtifactResultService(
                store: ArtifactStore(root: root, metadata: metadata),
                metadata: metadata
            )
        }

        let pluginResolver = AppPluginTaskResolver()
        self.pluginResolver = pluginResolver
        let resultProjections = PluginResultProjectionBox()
        self.resultProjections = resultProjections
        rendererCatalog = PluginRendererCatalog(entries: dependencies.pluginRendererEntries)
        let transferCoordinator = TransferCoordinator()
        let registrations = Self.taskRegistrations(
            pluginResolver: pluginResolver,
            credentialResolver: pluginService.credentialResolver,
            coordinator: executionCoordinator,
            projections: resultProjections,
            fileSources: fileSources,
            transferCoordinator: transferCoordinator
        )
        compositionResult = Result {
            try AppDurableHandlerComposition(
                taskRegistrations: registrations,
                resultHandlers: dependencies.pluginResultHandlers,
                rendererEntries: dependencies.pluginRendererEntries
            )
        }
    }

}
