import Foundation
import OpenFinderCore
import SwiftUI

enum PaneID: String {
    case left
    case right
}

@MainActor
final class AppModel: ObservableObject {
    static let videoAnalyzerVersion = "0.1.0"

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
    @Published var presentedVideoAnalysis: VideoAnalysisResult?
    @Published var presentedPluginResult: PluginResultProjection?
    @Published var pluginConnectionStatuses: [String: PluginConnectionStatus] = [:]
    @Published var durableHandlerReadiness: AppDurableHandlerReadiness = .checking
    @Published var configuration = AppConfiguration() {
        didSet {
            runtimeConfigurationService.publish(configuration)
            pluginManagementService.publish(configuration: configuration)
        }
    }

    let taskQueue: TaskQueueService
    let remoteDirectory: RemoteAccountDirectory
    let runtimeConfigurationService: RuntimeConfigurationService
    let pluginManagementService: PluginManagementService
    let remoteConnectorRegistry: RemoteConnectorRegistry
    let remoteProviderRegistry: RemoteProviderRegistry
    let fileSourceRegistry: FileSourceRegistry
    let remoteProviderResolver: @Sendable (RemoteLocation) async throws -> any RemoteProvider
    let videoAnalysisStore: VideoAnalysisResultStore
    let pluginRunnerRouter: PluginRunnerRouter
    let pluginExecutionCoordinator: PluginExecutionCoordinator
    let pluginWorkspaceMaintenance: PluginWorkspaceMaintenance
    let pluginRendererCatalog: PluginRendererCatalog
    let configurableProcessRunner: ConfigurableProcessPluginRunner?
    let pluginTaskResolver: AppPluginTaskResolver
    let pluginResultProjections: PluginResultProjectionBox
    let recoveryTaskStore: (any TaskStore)?
    let taskDatabaseOpenError: (any Error)?
    var durableReadinessTask: Task<Result<Void, any Error>, Never>?
    var taskPollingTask: Task<Void, Never>?
    var didLoadInitialState = false

    init(
        remoteDirectory: RemoteAccountDirectory? = nil,
        configurationStore: (any AppConfigurationStore)? = nil,
        keychainStore: KeychainStore? = nil,
        localPluginCredentialStore: LocalPluginCredentialStore? = nil,
        remoteConnectorRegistry: RemoteConnectorRegistry = .builtIn,
        remoteProviderRegistry: RemoteProviderRegistry? = nil,
        taskQueue: TaskQueueService? = nil,
        taskDatabaseURL: URL? = nil,
        videoAnalysisStore: VideoAnalysisResultStore? = nil,
        pluginRunnerRouter: PluginRunnerRouter? = nil,
        pluginConnectionChecker: (any PluginConnectionChecking)? = nil,
        pluginWorkspaceMaintenance: PluginWorkspaceMaintenance = .live(),
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
        self.remoteDirectory = remoteDirectory
        self.remoteConnectorRegistry = remoteConnectorRegistry
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
        self.taskQueue = configuredTaskQueue
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
        self.remoteProviderRegistry = configuredProviderRegistry
        let fileSourceRegistry = FileSourceRegistry(
            remoteProviderRegistry: configuredProviderRegistry
        )
        self.fileSourceRegistry = fileSourceRegistry
        let resolver: @Sendable (RemoteLocation) async throws -> any RemoteProvider = { location in
            try await configuredProviderRegistry.resolve(
                accountID: location.accountID.uuidString,
                revision: location.connectorID.rawValue
            )
        }
        remoteProviderResolver = resolver
        self.videoAnalysisStore = videoAnalysisStore ?? VideoAnalysisResultStore(
            directory: supportDirectory.appendingPathComponent("video-analysis", isDirectory: true)
        )
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
        let taskResolver = AppPluginTaskResolver()
        pluginTaskResolver = taskResolver
        let resultProjections = PluginResultProjectionBox()
        pluginResultProjections = resultProjections
        pluginRendererCatalog = PluginRendererCatalog(entries: pluginRendererEntries)
        leftPane = BrowserPaneModel(
            id: .left,
            location: .local(path: home.path),
            remoteProviderResolver: resolver,
            fileSourceRegistry: fileSourceRegistry
        )
        rightPane = BrowserPaneModel(
            id: .right,
            location: .local(path: home.appendingPathComponent("Downloads", isDirectory: true).path),
            remoteProviderResolver: resolver,
            fileSourceRegistry: fileSourceRegistry
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
                try await configuredTaskQueue.installHandlerRegistry(registry)
                if let store = self.recoveryTaskStore {
                    try await store.interruptActiveTasks(at: Date())
                    let persistedTasks = try await store.loadPersistedTasks()
                    try await configuredTaskQueue.restorePersistedHistory(persistedTasks)
                }
                await self.refreshTasks()
                if startAutomatically {
                    await self.loadInitialState()
                    await self.pluginTaskResolver.register(self.loadedPlugins)
                }
                await configuredTaskQueue.resumeRecoveredTasks()
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
