import Foundation
import OpenFinderCore
import SwiftUI

enum PaneID: String {
    case left
    case right
}

@MainActor
final class AppModel: ObservableObject {
    @Published var leftPane: BrowserPaneModel
    @Published var rightPane: BrowserPaneModel
    @Published var activePane: PaneID = .left
    @Published var taskRecords: [TaskRecord] = []
    @Published var taskLogs: [UUID: [TaskLogLine]] = [:]
    @Published var loadedPlugins: [LoadedPlugin] = []
    @Published var pluginLoadDiagnostics: [PluginLoadDiagnostic] = []
    @Published var remoteAccounts: [RemoteAccount] = []
    @Published var statusMessage: String = "Ready"
    @Published var pendingTransferOverwrite: PendingTransferOverwrite?
    @Published var presentedPluginResult: PluginResultProjection?
    @Published var pluginConnectionStatuses: [String: PluginConnectionStatus] = [:]
    @Published var durableHandlerReadiness: AppDurableHandlerReadiness = .checking
    @Published var configuration = AppConfiguration() {
        didSet {
            runtimeConfigurationService.publish(configuration)
            pluginManagementService.publish(configuration: configuration)
        }
    }

    let taskApplicationService: TaskApplicationService
    let remoteAccountService: RemoteAccountService
    let fileBrowserService: FileBrowserService
    let runtimeConfigurationService: RuntimeConfigurationService
    let pluginManagementService: PluginManagementService
    let pluginRunnerRouter: PluginRunnerRouter
    let pluginExecutionCoordinator: PluginExecutionCoordinator
    let pluginWorkspaceMaintenance: PluginWorkspaceMaintenance
    let pluginRendererCatalog: PluginRendererCatalog
    let artifactResultService: ArtifactResultService?
    let configurableProcessRunner: ConfigurableProcessPluginRunner?
    let pluginTaskResolver: AppPluginTaskResolver
    let pluginResultProjections: PluginResultProjectionBox
    let recoveryTaskStore: (any TaskStore)?
    let taskDatabaseOpenError: (any Error)?
    var durableReadinessTask: Task<Result<Void, any Error>, Never>?
    var didLoadInitialState = false

    var taskQueue: TaskQueueService { taskApplicationService.queue }

    init(
        remoteDirectory: RemoteAccountDirectory? = nil,
        configurationStore: (any AppConfigurationStore)? = nil,
        keychainStore: KeychainStore? = nil,
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let supportDirectory = Self.applicationSupportDirectory()
        let remoteDirectory = remoteDirectory ?? RemoteAccountDirectory(
            storageURL: supportDirectory.appendingPathComponent("remote-accounts.json")
        )
        let configurationStore = configurationStore ?? JSONConfigStore(
            url: supportDirectory.appendingPathComponent("config.json")
        )
        let keychainStore = keychainStore ?? MacKeychainStore()
        let localPluginCredentialStore = localPluginCredentialStore ?? LocalPluginCredentialStore()
        var openedTaskStore: (any TaskStore)?
        var taskDatabaseOpenError: (any Error)?
        if let taskDatabaseURL {
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
        recoveryTaskStore = openedTaskStore
        self.taskDatabaseOpenError = taskDatabaseOpenError
        let configuredTaskQueue = taskQueue ?? TaskQueueService(
            maxConcurrentTasks: 2,
            store: openedTaskStore
        )
        let taskService = TaskApplicationService(queue: configuredTaskQueue)
        taskApplicationService = taskService
        let configurationService = RuntimeConfigurationService(
            store: configurationStore,
            taskQueue: configuredTaskQueue
        )
        self.runtimeConfigurationService = configurationService
        let pluginService = PluginManagementService(
            configurationService: configurationService,
            keychainStore: keychainStore,
            localCredentialStore: localPluginCredentialStore,
            connectionChecker: pluginConnectionChecker
        )
        self.pluginManagementService = pluginService
        let configuredProviderRegistry = remoteProviderRegistry ?? RemoteProviderRegistry(
            connectorRegistry: remoteConnectorRegistry,
            account: { accountID in
                guard let accountID = UUID(uuidString: accountID) else { return nil }
                return remoteDirectory.account(id: accountID)
            },
            credentialStore: pluginService.credentialStore
        )
        let fileSourceRegistry = FileSourceRegistry(
            remoteProviderRegistry: configuredProviderRegistry
        )
        remoteAccountService = RemoteAccountService(
            directory: remoteDirectory,
            connectorRegistry: remoteConnectorRegistry,
            providerRegistry: configuredProviderRegistry,
            keychainStore: keychainStore
        )
        let browserService = FileBrowserService(
            fileSourceRegistry: fileSourceRegistry,
            taskService: taskService
        )
        self.fileBrowserService = browserService
        let resolver: @Sendable (RemoteLocation) async throws -> any RemoteProvider = { location in
            try await configuredProviderRegistry.resolve(
                accountID: location.accountID.uuidString,
                revision: location.connectorID.rawValue
            )
        }
        let pluginCredentialResolver = pluginService.credentialResolver
        let configuredRunner: PluginRunnerRouter
        if let pluginRunnerRouter {
            configuredRunner = pluginRunnerRouter
            configurableProcessRunner = nil
        } else {
            let processRunner = ConfigurableProcessPluginRunner()
            configuredRunner = PluginRunnerRouter(
                processRunner: processRunner,
                httpRunner: HTTPPluginRunner(credentialResolver: pluginCredentialResolver)
            )
            configurableProcessRunner = processRunner
        }
        self.pluginRunnerRouter = configuredRunner
        configurationService.attach(processRunner: configurableProcessRunner)
        let configuredConnectionChecker = pluginService.connectionChecking
        let resultHandlerRegistry = (try? PluginResultHandlerRegistry(
            handlers: pluginResultHandlers
        )) ?? .standard
        let coordinator = PluginExecutionCoordinator(
            runner: configuredRunner,
            connectionChecker: configuredConnectionChecker,
            credentialResolver: pluginCredentialResolver,
            resultHandlers: resultHandlerRegistry,
            workspaceMaintenance: .init { workspace in
                try pluginWorkspaceMaintenance.cleanup(.init(executionWorkspace: workspace))
            }
        )
        self.pluginExecutionCoordinator = coordinator
        self.pluginWorkspaceMaintenance = pluginWorkspaceMaintenance
        if let artifactResultService {
            self.artifactResultService = artifactResultService
        } else {
            let metadata = InMemoryArtifactMetadataBackend()
            let artifactRoot = supportDirectory.appendingPathComponent("artifacts", isDirectory: true)
            if let store = try? ArtifactStore(root: artifactRoot, metadata: metadata) {
                self.artifactResultService = ArtifactResultService(store: store, metadata: metadata)
            } else {
                self.artifactResultService = nil
            }
        }
        let taskResolver = AppPluginTaskResolver()
        pluginTaskResolver = taskResolver
        let resultProjections = PluginResultProjectionBox()
        pluginResultProjections = resultProjections
        pluginRendererCatalog = PluginRendererCatalog(entries: pluginRendererEntries)
        leftPane = BrowserPaneModel(
            id: .left,
            location: .local(path: home.path),
            remoteProviderResolver: resolver,
            fileSourceRegistry: fileSourceRegistry,
            fileBrowserService: browserService
        )
        rightPane = BrowserPaneModel(
            id: .right,
            location: .local(path: home.appendingPathComponent("Downloads", isDirectory: true).path),
            remoteProviderResolver: resolver,
            fileSourceRegistry: fileSourceRegistry,
            fileBrowserService: browserService
        )
        let transferCoordinator = TransferCoordinator()
        let registrations = [
            AppDurableHandlerComposition.TaskRegistration(
                handler: PluginExecuteTaskHandler(
                    pluginResolver: PluginTaskPluginResolver { pluginID, pluginVersion in
                        try await taskResolver.resolve(
                            pluginID: pluginID,
                            pluginVersion: pluginVersion
                        )
                    },
                    credentialResolver: pluginCredentialResolver,
                    coordinator: coordinator,
                    publish: { taskID, projection in
                        await resultProjections.store(projection, for: taskID)
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
            AppDurableHandlerComposition.TaskRegistration(
                handler: TransferCopyTaskHandler(
                    fileSources: fileSourceRegistry,
                    coordinator: transferCoordinator
                ).taskHandler,
                dependencies: [.fileSourceRegistry, .transferCoordinator]
            ),
            AppDurableHandlerComposition.TaskRegistration(
                handler: TransferMoveTaskHandler(
                    fileSources: fileSourceRegistry,
                    coordinator: transferCoordinator
                ).taskHandler,
                dependencies: [.fileSourceRegistry, .transferCoordinator]
            ),
        ]
        let compositionResult = Result {
            try AppDurableHandlerComposition(
                taskRegistrations: registrations,
                resultHandlers: pluginResultHandlers,
                rendererEntries: pluginRendererEntries
            )
        }
        durableReadinessTask = Task { [weak self] in
            guard let self else {
                return .failure(CancellationError())
            }
            do {
                if let taskDatabaseOpenError = self.taskDatabaseOpenError {
                    throw taskDatabaseOpenError
                }
                let composition = try compositionResult.get()
                let registry = try await composition.makeTaskHandlerRegistry()
                try await self.taskApplicationService.installHandlerRegistry(registry)
                if let store = self.recoveryTaskStore {
                    try await self.taskApplicationService.recoverPersistedTasks(from: store)
                }
                await self.refreshTasks()
                if startAutomatically {
                    await self.loadInitialState()
                    await self.pluginTaskResolver.register(self.loadedPlugins)
                }
                await self.taskApplicationService.resumeRecoveredTasks()
                self.durableHandlerReadiness = .ready
                if startAutomatically {
                    self.startTaskPolling()
                }
                return .success(())
            } catch {
                self.durableHandlerReadiness = .unavailable(error.localizedDescription)
                if startAutomatically {
                    await self.loadInitialState()
                    self.startTaskPolling()
                }
                return .failure(error)
            }
        }
        taskService.attachReadinessTask(durableReadinessTask!)
    }

    var activeBrowser: BrowserPaneModel { activePane == .left ? leftPane : rightPane }
    var inactiveBrowser: BrowserPaneModel { activePane == .left ? rightPane : leftPane }

    func browser(for id: PaneID) -> BrowserPaneModel {
        id == .left ? leftPane : rightPane
    }
}

struct PendingDeletion: Identifiable {
    let id = UUID()
    let items: [FileItem]
}

struct PendingTransferOverwrite: Identifiable {
    let id = UUID()
    let items: [FileItem]
    let source: Location
    let destination: Location
    let move: Bool
    let conflicts: [TransferConflict]
    let sourcePaneID: PaneID
    let destinationPaneID: PaneID

    var message: String {
        let names = conflicts.prefix(5).map(\.itemName).joined(separator: ", ")
        let remaining = conflicts.count > 5 ? " 等另外 \(conflicts.count - 5) 项" : ""
        let action = move ? "移动" : "复制"
        return "\(action)目标位置已存在 \(conflicts.count) 个同名项目：\(names)\(remaining)。是否覆盖现有项目？"
    }
}
