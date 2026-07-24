import Foundation
import OpenFinderCore
import SwiftUI

enum PaneID: String {
    case left
    case right
}

@MainActor
final class AppModel: ObservableObject {
    static let videoAnalyzerPluginID = "dev.openfinder.plugins.video-analyzer"
    static let videoAnalyzerActionID = "analyze-video"
    static let videoAnalyzerResourceKey = "video-analysis"
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
    @Published var configuration = AppConfiguration() {
        didSet {
            localPluginCredentialStore.replace(pluginSecrets: configuration.localPluginSecrets)
            if configurationPersistenceIsDeferred {
                configurationSaveWasDeferred = true
            } else {
                saveConfiguration()
            }
            let python3Path = configuration.python3Path
            let nodePath = configuration.nodePath
            let maxConcurrentTasks = configuration.maxConcurrentTasks
            let previousRuntimeUpdate = configurationRuntimeUpdateTask
            let taskQueue = taskQueue
            let processRunner = configurableProcessRunner
            configurationRuntimeUpdateTask = Task {
                await previousRuntimeUpdate?.value
                await taskQueue.updateMaxConcurrentTasks(maxConcurrentTasks)
                if let processRunner {
                    await processRunner.update(python3Path: python3Path, nodePath: nodePath)
                }
            }
        }
    }

    let taskQueue: TaskQueueService
    let remoteDirectory: RemoteAccountDirectory
    let keychainStore: KeychainStore
    let localPluginCredentialStore: LocalPluginCredentialStore
    let pluginCredentialResolver: PluginCredentialResolver
    let configurationStore: any AppConfigurationStore
    let pluginRegistry = PluginRegistry()
    let remoteConnectorRegistry: RemoteConnectorRegistry
    let remoteProviderRegistry: RemoteProviderRegistry
    let remoteProviderResolver: @Sendable (RemoteLocation) async throws -> any RemoteProvider
    let videoAnalysisStore: VideoAnalysisResultStore
    let pluginRunnerRouter: PluginRunnerRouter
    let pluginConnectionChecker: any PluginConnectionChecking
    let pluginExecutionCoordinator: PluginExecutionCoordinator
    let pluginWorkspaceMaintenance: PluginWorkspaceMaintenance
    let configurableProcessRunner: ConfigurableProcessPluginRunner?
    var taskPollingTask: Task<Void, Never>?
    var configurationSaveTask: Task<Void, Never>?
    var configurationRuntimeUpdateTask: Task<Void, Never>?
    let configurationPersistenceGate = ConfigurationPersistenceGate()
    var configurationPersistenceIsDeferred = false
    var configurationSaveWasDeferred = false
    var didLoadInitialState = false

    init(
        remoteDirectory: RemoteAccountDirectory? = nil,
        configurationStore: (any AppConfigurationStore)? = nil,
        keychainStore: KeychainStore? = nil,
        localPluginCredentialStore: LocalPluginCredentialStore? = nil,
        remoteConnectorRegistry: RemoteConnectorRegistry = .builtIn,
        remoteProviderRegistry: RemoteProviderRegistry? = nil,
        taskQueue: TaskQueueService? = nil,
        videoAnalysisStore: VideoAnalysisResultStore? = nil,
        pluginRunnerRouter: PluginRunnerRouter? = nil,
        pluginConnectionChecker: (any PluginConnectionChecking)? = nil,
        pluginWorkspaceMaintenance: PluginWorkspaceMaintenance = .live(),
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
        self.keychainStore = keychainStore
        self.localPluginCredentialStore = localPluginCredentialStore
        self.configurationStore = configurationStore
        self.remoteConnectorRegistry = remoteConnectorRegistry
        let configuredProviderRegistry = remoteProviderRegistry ?? RemoteProviderRegistry(
            connectorRegistry: remoteConnectorRegistry,
            account: { accountID in
                guard let accountID = UUID(uuidString: accountID) else { return nil }
                return remoteDirectory.account(id: accountID)
            },
            credentialStore: keychainStore
        )
        self.remoteProviderRegistry = configuredProviderRegistry
        let fileSourceRegistry = FileSourceRegistry(
            remoteProviderRegistry: configuredProviderRegistry
        )
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
        self.taskQueue = taskQueue ?? TaskQueueService(maxConcurrentTasks: 2)
        let pluginCredentialResolver = PluginCredentialResolver(
            keychainStore: keychainStore,
            localStore: localPluginCredentialStore
        )
        self.pluginCredentialResolver = pluginCredentialResolver
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
        let configuredConnectionChecker = pluginConnectionChecker
            ?? HTTPPluginConnectionProbe(credentialResolver: pluginCredentialResolver)
        self.pluginConnectionChecker = configuredConnectionChecker
        self.pluginExecutionCoordinator = PluginExecutionCoordinator(
            runner: configuredRunner,
            connectionChecker: configuredConnectionChecker,
            credentialResolver: pluginCredentialResolver,
            workspaceMaintenance: .init { workspace in
                try pluginWorkspaceMaintenance.cleanup(.init(executionWorkspace: workspace))
            }
        )
        self.pluginWorkspaceMaintenance = pluginWorkspaceMaintenance
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
        if startAutomatically {
            Task { await loadInitialState() }
            startTaskPolling()
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
