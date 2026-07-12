import AppKit
import Foundation
import OpenFinderCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum PaneID: String {
        case left
        case right
    }

    @Published var leftPane: BrowserPaneModel
    @Published var rightPane: BrowserPaneModel
    @Published var activePane: PaneID = .left
    @Published var taskRecords: [TaskRecord] = []
    @Published var taskLogs: [UUID: [TaskLogLine]] = [:]
    @Published var loadedPlugins: [LoadedPlugin] = []
    @Published var remoteAccounts: [RemoteAccount] = []
    @Published var statusMessage: String = "Ready"
    @Published var pendingTransferOverwrite: PendingTransferOverwrite?
    @Published var configuration = AppConfiguration() {
        didSet { saveConfiguration() }
    }

    let taskQueue: TaskQueueService
    private let remoteDirectory: RemoteAccountDirectory
    private let keychainStore: KeychainStore
    private let configurationStore: JSONConfigStore
    private let pluginRegistry = PluginRegistry()
    private let remoteConnectorRegistry: RemoteConnectorRegistry
    private let remoteProviderRegistry: RemoteProviderRegistry
    private let remoteProviderResolver: @Sendable (RemoteLocation) async throws -> any RemoteProvider
    private var taskPollingTask: Task<Void, Never>?
    private var didLoadInitialState = false

    init(
        remoteDirectory: RemoteAccountDirectory? = nil,
        configurationStore: JSONConfigStore? = nil,
        keychainStore: KeychainStore? = nil,
        remoteConnectorRegistry: RemoteConnectorRegistry = .builtIn,
        remoteProviderRegistry: RemoteProviderRegistry? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let remoteDirectory = remoteDirectory ?? RemoteAccountDirectory(storageURL: Self.applicationSupportDirectory().appendingPathComponent("remote-accounts.json"))
        let configurationStore = configurationStore ?? JSONConfigStore(url: Self.applicationSupportDirectory().appendingPathComponent("config.json"))
        let keychainStore = keychainStore ?? MacKeychainStore()
        self.remoteDirectory = remoteDirectory
        self.keychainStore = keychainStore
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
        let remoteProviderResolver: @Sendable (RemoteLocation) async throws -> any RemoteProvider = { location in
            try await configuredProviderRegistry.resolve(
                accountID: location.accountID.uuidString,
                revision: location.connectorID.rawValue
            )
        }
        self.remoteProviderResolver = remoteProviderResolver
        self.taskQueue = TaskQueueService(maxConcurrentTasks: 2)
        self.leftPane = BrowserPaneModel(
            id: .left,
            location: .local(path: home.path),
            remoteProviderResolver: remoteProviderResolver
        )
        self.rightPane = BrowserPaneModel(
            id: .right,
            location: .local(path: home.appendingPathComponent("Downloads", isDirectory: true).path),
            remoteProviderResolver: remoteProviderResolver
        )
        Task {
            await loadInitialState()
        }
        startTaskPolling()
    }

    var activeBrowser: BrowserPaneModel { activePane == .left ? leftPane : rightPane }
    var inactiveBrowser: BrowserPaneModel { activePane == .left ? rightPane : leftPane }

    private func browser(for id: PaneID) -> BrowserPaneModel {
        id == .left ? leftPane : rightPane
    }

    func loadInitialState() async {
        guard !didLoadInitialState else { return }
        didLoadInitialState = true
        if let loadedConfiguration = try? await configurationStore.load() {
            configuration = loadedConfiguration
        }
        await leftPane.refresh()
        await rightPane.refresh()
        loadPlugins()
        remoteAccounts = remoteDirectory.all()
        await refreshTasks()
    }

    var remoteConnectors: [RemoteConnector] { remoteConnectorRegistry.connectors }

    func loadPlugins() {
        var plugins: [LoadedPlugin] = []
        let projectPlugins = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("ExamplePlugins", isDirectory: true)
        let bundledPlugins = Bundle.main.resourceURL?.appendingPathComponent("BuiltinPlugins", isDirectory: true)
        let appSupportPlugins = Self.applicationSupportDirectory().appendingPathComponent("Plugins", isDirectory: true)
        for directory in [projectPlugins, bundledPlugins, appSupportPlugins].compactMap({ $0 }) {
            if let scanned = try? pluginRegistry.scan(directory: directory) {
                plugins.append(contentsOf: scanned)
            }
        }
        loadedPlugins = Array(Dictionary(grouping: plugins, by: \.id).compactMap { $0.value.first })
    }

    func pluginActions(for items: [FileItem]) -> [(LoadedPlugin, PluginActionManifest)] {
        loadedPlugins.flatMap { plugin in
            PluginMatcher.actions(in: plugin.manifest, matching: items).map { (plugin, $0) }
        }
    }

    func runPlugin(_ plugin: LoadedPlugin, action: PluginActionManifest, items: [FileItem], pane: BrowserPaneModel) {
        Task {
            let taskID = UUID()
            let workspace = PluginWorkspace.make(taskID: taskID, currentLocation: pane.location)
            try? FileManager.default.createDirectory(at: workspace.tempDirectory, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: workspace.outputDirectory, withIntermediateDirectories: true)
            let resolvedConfiguration = PluginConfigurationResolver.resolve(
                manifest: plugin.manifest,
                values: configuration.pluginConfigurationValues[plugin.id] ?? [:],
                secretReferences: configuredPluginSecretReferences(for: plugin.manifest)
            )
            let input = PluginInput(
                schemaVersion: 1,
                taskID: taskID,
                actionID: action.id,
                app: .init(name: "OpenFinder", version: "0.1.0"),
                context: .init(activePane: pane.id.rawValue, currentLocation: pane.location),
                files: items.map(PluginInputFile.init(item:)),
                config: resolvedConfiguration.config,
                secrets: resolvedConfiguration.secrets,
                tempDirectory: workspace.tempDirectory.path,
                outputDirectory: workspace.outputDirectory.path
            )
            do {
                let runner = ProcessPluginRunner(runtimePaths: .init(python3Path: configuration.python3Path, nodePath: configuration.nodePath))
                let queuedID = try await taskQueue.enqueue(.init(kind: .plugin(pluginID: plugin.id, actionID: action.id), title: "\(plugin.manifest.name): \(action.title)") { context in
                    await context.appendLog("Starting plugin \(plugin.manifest.name) / \(action.title)")
                    let result = try await runner.run(.init(
                        manifest: plugin.manifest,
                        action: action,
                        input: input,
                        environment: [:],
                        pluginDirectory: plugin.directory,
                        workingDirectory: plugin.directory,
                        onEvent: { event in
                            Task {
                                switch event {
                                case .log(let level, let message):
                                    await context.appendLog(message, level: level)
                                case .progress(let fraction, let message):
                                    await context.updateProgress(fraction, message)
                                case .result(_, let message, _, _):
                                    if let message { await context.appendLog(message) }
                                }
                            }
                        }
                    ))
                    if result.exitCode != 0 {
                        throw OpenFinderError.operationFailed(result.stderr.isEmpty ? "Plugin exited with \(result.exitCode)" : result.stderr)
                    }
                    if let failure = result.events.last(where: { $0.isFailureResult }) {
                        throw OpenFinderError.operationFailed(failure.resultMessage ?? "Plugin reported failure")
                    }
                    return .success(summary: result.events.compactMap { event in
                        if case .result(_, let message, _, _) = event { return message }
                        return nil
                    }.last ?? "Plugin completed", clipboard: result.events.compactMap(\.clipboardText).last)
                })
                statusMessage = "Queued plugin task \(queuedID.uuidString.prefix(8))"
                await observeTask(queuedID)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func dropLocalFileURLs(_ urls: [URL], into pane: BrowserPaneModel) {
        activePane = pane.id
        let destinationLocation = pane.location
        Task {
            do {
                let items = try await DroppedLocalFileItems.resolve(urls)
                guard !items.isEmpty else { return }
                let sourceLocation = items.first?.location ?? .local(path: urls[0].deletingLastPathComponent().path)
                let title = "Copy dropped \(items.count) item(s)"
                let queuedID = try await taskQueue.enqueue(.init(kind: .localCopy, title: title) { context in
                    await context.appendLog("\(title) to \(destinationLocation.displayPath)")
                    try await FileTransferService.copyOrMove(
                        items,
                        from: sourceLocation,
                        to: destinationLocation,
                        move: false,
                        remoteProviderResolver: self.remoteProviderResolver,
                        progress: { fraction, message in
                            Task { await context.updateProgress(fraction, message) }
                        }
                    )
                    await context.updateProgress(1.0, "Finished")
                    return .success(summary: title, clipboard: nil)
                })
                await observeTask(queuedID)
                await pane.refresh()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func copySelectionToOtherPane(move: Bool) {
        let source = activeBrowser
        let destination = inactiveBrowser
        let selected = source.selectedItems
        let sourceLocation = source.location
        let destinationLocation = destination.location
        guard !selected.isEmpty else { return }
        let conflicts = TransferConflictDetector.conflicts(for: selected, destination: destinationLocation)
        if !conflicts.isEmpty {
            pendingTransferOverwrite = PendingTransferOverwrite(
                items: selected,
                source: sourceLocation,
                destination: destinationLocation,
                move: move,
                conflicts: conflicts,
                sourcePaneID: source.id,
                destinationPaneID: destination.id
            )
            return
        }
        enqueueTransfer(
            selected,
            source: sourceLocation,
            destination: destinationLocation,
            move: move,
            overwriteExisting: false,
            sourcePaneID: source.id,
            destinationPaneID: destination.id
        )
    }

    func confirmPendingTransferOverwrite(_ confirmedPending: PendingTransferOverwrite? = nil) {
        guard let pending = confirmedPending ?? pendingTransferOverwrite else { return }
        pendingTransferOverwrite = nil
        enqueueTransfer(
            pending.items,
            source: pending.source,
            destination: pending.destination,
            move: pending.move,
            overwriteExisting: true,
            sourcePaneID: pending.sourcePaneID,
            destinationPaneID: pending.destinationPaneID
        )
    }

    func cancelPendingTransferOverwrite() {
        pendingTransferOverwrite = nil
    }

    private func enqueueTransfer(
        _ selected: [FileItem],
        source sourceLocation: Location,
        destination destinationLocation: Location,
        move: Bool,
        overwriteExisting: Bool,
        sourcePaneID: PaneID,
        destinationPaneID: PaneID
    ) {
        Task {
            do {
                let title = move ? "Move \(selected.count) item(s)" : "Copy \(selected.count) item(s)"
                let queuedID = try await taskQueue.enqueue(.init(kind: move ? .localMove : .localCopy, title: title) { context in
                    await context.appendLog("\(title) to \(destinationLocation.displayPath)")
                    try await FileTransferService.copyOrMove(
                        selected,
                        from: sourceLocation,
                        to: destinationLocation,
                        move: move,
                        overwriteExisting: overwriteExisting,
                        remoteProviderResolver: self.remoteProviderResolver,
                        progress: { fraction, message in
                            Task { await context.updateProgress(fraction, message) }
                        }
                    )
                    await context.updateProgress(1.0, "Finished")
                    return .success(summary: title, clipboard: nil)
                })
                await observeTask(queuedID)
                await browser(for: sourcePaneID).refresh()
                await browser(for: destinationPaneID).refresh()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }


    func addWebDAVAccount(name: String, baseURL: String, username: String, password: String, allowInsecureHTTP: Bool) {
        addRemoteAccount(
            connectorID: .webDAV,
            name: name,
            endpoint: baseURL,
            username: username,
            password: password,
            allowInsecureHTTP: allowInsecureHTTP
        )
    }

    func addRemoteAccount(connectorID: RemoteConnectorID, name: String, endpoint: String, username: String, password: String, allowInsecureHTTP: Bool) {
        do {
            guard let connector = remoteConnectorRegistry.connector(id: connectorID) else {
                throw OpenFinderError.operationFailed("Unknown remote connector: \(connectorID.rawValue)")
            }
            let accountID = UUID()
            let secretRef = "remote.\(connector.id.rawValue).\(accountID.uuidString).password"
            let account = try connector.makeAccount(
                id: accountID,
                name: name,
                endpoint: endpoint,
                username: username,
                secretKeychainRef: password.isEmpty ? nil : secretRef,
                allowInsecureHTTP: allowInsecureHTTP
            )
            if !password.isEmpty {
                try keychainStore.setSecret(password, for: secretRef)
            }
            remoteDirectory.save(account)
            remoteAccounts = remoteDirectory.all()
            statusMessage = "Added \(connector.displayName) account \(account.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeWebDAVAccount(_ account: RemoteAccount) {
        removeRemoteAccount(account)
    }

    func removeRemoteAccount(_ account: RemoteAccount) {
        Task {
            await remoteProviderRegistry.invalidate(accountID: account.id.uuidString)
            do {
                if let ref = account.secretKeychainRef { try keychainStore.deleteSecret(for: ref) }
                remoteDirectory.remove(id: account.id)
                remoteAccounts = remoteDirectory.all()
                let connectorName = remoteConnectorRegistry.connector(for: account)?.displayName ?? "Remote"
                statusMessage = "Removed \(connectorName) account \(account.name)"
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func openWebDAVAccountInActivePane(_ account: RemoteAccount) {
        openRemoteAccountInActivePane(account)
    }

    func openRemoteAccountInActivePane(_ account: RemoteAccount) {
        Task {
            guard let connector = remoteConnectorRegistry.connector(for: account) else {
                statusMessage = "No connector is available for \(account.name)"
                return
            }
            let root = connector.providerKind == .kodbox
                ? RemotePath(identifier: KodboxProvider.syntheticRootIdentifier, displayPath: "/")
                : RemotePath(identifier: "/", displayPath: "/")
            await activeBrowser.navigate(to: .remote(.init(
                accountID: account.id,
                connectorID: connector.id,
                path: root
            )))
        }
    }

    @discardableResult
    func refreshTasks() async -> Bool {
        let records = await taskQueue.history().sorted { $0.createdAt > $1.createdAt }
        var logs: [UUID: [TaskLogLine]] = [:]
        for record in records {
            logs[record.id] = await taskQueue.logs(for: record.id)
        }
        if taskRecords != records {
            taskRecords = records
        }
        if taskLogs != logs {
            taskLogs = logs
        }
        return records.contains { !$0.status.isTerminal }
    }

    func cancelTask(_ id: UUID) {
        Task {
            await taskQueue.cancel(id)
            statusMessage = "Cancelled task \(id.uuidString.prefix(8))"
            await refreshTasks()
        }
    }

    func retryTask(_ id: UUID) {
        Task {
            do {
                let retryID = try await taskQueue.retry(id)
                statusMessage = "Retried task \(retryID.uuidString.prefix(8))"
                await refreshTasks()
                await observeTask(retryID)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func copyLogs(for id: UUID) {
        let text = (taskLogs[id] ?? []).map { line in
            "[\(line.level)] \(line.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied logs for \(id.uuidString.prefix(8))"
    }

    private func startTaskPolling() {
        taskPollingTask?.cancel()
        taskPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let hasActiveTasks = await self?.refreshTasks() ?? false
                let interval: UInt64 = hasActiveTasks ? 250_000_000 : 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func observeTask(_ id: UUID) async {
        do {
            let record = try await taskQueue.waitForTerminalStatus(id, timeout: 86_400)
            if let clipboard = record.clipboardText {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clipboard, forType: .string)
            }
            await refreshTasks()
        } catch {
            statusMessage = error.localizedDescription
            await refreshTasks()
        }
    }

    func revealSelectedInFinder() {
        activeBrowser.revealSelectedInFinder()
    }

    func openSelectedInTerminal() {
        activeBrowser.openSelectedInTerminal()
    }

    func quickLookSelected() {
        activeBrowser.quickLookSelected()
    }

    func pluginConfigValue(pluginID: String, key: String) -> String {
        configuration.pluginConfigurationValues[pluginID]?[key] ?? ""
    }

    func setPluginConfigValue(_ value: String, pluginID: String, key: String) {
        var next = configuration
        var pluginValues = next.pluginConfigurationValues[pluginID] ?? [:]
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pluginValues.removeValue(forKey: key)
        } else {
            pluginValues[key] = value
        }
        next.pluginConfigurationValues[pluginID] = pluginValues.isEmpty ? nil : pluginValues
        configuration = next
    }

    func pluginSecretConfigured(pluginID: String, key: String) -> Bool {
        (try? keychainStore.secret(for: pluginSecretReference(pluginID: pluginID, key: key))) != nil
    }

    func setPluginSecret(_ secret: String, pluginID: String, key: String) {
        do {
            let reference = pluginSecretReference(pluginID: pluginID, key: key)
            if secret.isEmpty {
                try keychainStore.deleteSecret(for: reference)
                statusMessage = "Cleared plugin secret \(key)"
            } else {
                try keychainStore.setSecret(secret, for: reference)
                statusMessage = "Saved plugin secret \(key)"
            }
            objectWillChange.send()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func configuredPluginSecretReferences(for manifest: PluginManifest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: manifest.permissions.keychainSecrets.compactMap { key in
            let reference = pluginSecretReference(pluginID: manifest.id, key: key)
            guard (try? keychainStore.secret(for: reference)) != nil else { return nil }
            return (key, reference)
        })
    }

    private func pluginSecretReference(pluginID: String, key: String) -> String {
        "plugin.\(pluginID).\(key)"
    }

    private func saveConfiguration() {
        let configuration = configuration
        let store = configurationStore
        Task {
            try? await store.save(configuration)
        }
    }

    static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("OpenFinder", isDirectory: true)
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
    let sourcePaneID: AppModel.PaneID
    let destinationPaneID: AppModel.PaneID

    var message: String {
        let names = conflicts.prefix(5).map(\.itemName).joined(separator: ", ")
        let remaining = conflicts.count > 5 ? " 等另外 \(conflicts.count - 5) 项" : ""
        let action = move ? "移动" : "复制"
        return "\(action)目标位置已存在 \(conflicts.count) 个同名项目：\(names)\(remaining)。是否覆盖现有项目？"
    }
}

private struct TagEditorSession {
    let generation: UInt64
    let location: Location
    let context: TagEditorContext
    let provider: any TagProvider
}

private struct BrowserPaneListing {
    let items: [FileItem]
    let remoteParent: RemotePath?
}

@MainActor
final class BrowserPaneModel: ObservableObject, Identifiable {
    let id: AppModel.PaneID
    @Published var location: Location {
        didSet {
            guard location != oldValue else { return }
            locationGeneration &+= 1
            invalidateTagEditorSession()
        }
    }
    @Published var items: [FileItem] = []
    @Published var selection: Set<String> = [] {
        didSet {
            guard selection != oldValue, !isRestoringTagEditorSelection else { return }
            invalidateTagEditorSession()
        }
    }
    @Published var filterText: String = ""
    @Published var showHiddenFiles: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var pendingDeletion: PendingDeletion?
    @Published var directorySizeText: [String: String] = [:]
    @Published private(set) var history: [Location]
    @Published private(set) var historyIndex: Int = 0

    private let provider = LocalFileProvider()
    private let remoteProviderResolver: @Sendable (RemoteLocation) async throws -> any RemoteProvider
    private var directorySizeCache: [String: Int64] = [:]
    private var directorySizeTasks: [String: Task<Void, Never>] = [:]
    private var remoteParent: RemotePath?
    private let remoteMaterializationDirectory: URL
    private var tagEditorSession: TagEditorSession?
    private var tagEditorGeneration: UInt64 = 0
    private var locationGeneration: UInt64 = 0
    private var isRestoringTagEditorSelection = false

    init(
        id: AppModel.PaneID,
        location: Location,
        remoteProviderResolver: @escaping @Sendable (RemoteLocation) async throws -> any RemoteProvider
    ) {
        self.id = id
        self.location = location
        self.history = [location]
        self.remoteProviderResolver = remoteProviderResolver
        self.remoteMaterializationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderRemoteFiles-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        for task in directorySizeTasks.values { task.cancel() }
        try? FileManager.default.removeItem(at: remoteMaterializationDirectory)
    }

    var visibleItems: [FileItem] {
        FileBrowserFilter.apply(items, text: filterText)
    }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.id) }
    }

    func openFirstSelected() {
        guard let item = selectedItems.first else { return }
        open(item)
    }

    func selectAllVisible() {
        selection = Set(visibleItems.map(\.id))
    }

    var hasRemoteSelection: Bool {
        selectedItems.contains { item in
            if case .local = item.location { return false }
            return true
        }
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }

    func refresh() async {
        await refresh(preservingTagEditorSession: nil)
    }

    private func refresh(preservingTagEditorSession session: TagEditorSession?) async {
        let refreshedLocation = location
        let refreshedLocationGeneration = locationGeneration
        isLoading = true
        errorMessage = nil
        remoteParent = nil
        defer { isLoading = false }
        do {
            let listing = try await listItems(at: refreshedLocation)
            guard location == refreshedLocation,
                  locationGeneration == refreshedLocationGeneration
            else {
                return
            }
            if let session, !isCurrentTagEditorSession(session) {
                return
            }
            remoteParent = listing.remoteParent
            items = listing.items
            if session != nil {
                isRestoringTagEditorSelection = true
                selection.formIntersection(Set(items.map(\.id)))
                isRestoringTagEditorSelection = false
            } else {
                selection.formIntersection(Set(items.map(\.id)))
            }
            refreshDirectorySizeCalculations(for: items)
        } catch {
            guard location == refreshedLocation,
                  locationGeneration == refreshedLocationGeneration,
                  session.map(isCurrentTagEditorSession) ?? true
            else {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func navigate(to newLocation: Location, recordHistory: Bool = true) async {
        location = newLocation
        selection = []
        if recordHistory {
            if historyIndex + 1 < history.count { history.removeSubrange((historyIndex + 1)..<history.count) }
            history.append(newLocation)
            historyIndex = history.count - 1
        }
        await refresh()
    }

    func open(_ item: FileItem) {
        if item.isDirectory {
            Task { await navigate(to: item.location) }
        } else if let url = item.localURL {
            NSWorkspace.shared.open(url)
        } else {
            Task {
                do {
                    NSWorkspace.shared.open(try await materializeRemoteFile(item))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        Task { await navigate(to: history[historyIndex], recordHistory: false) }
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        Task { await navigate(to: history[historyIndex], recordHistory: false) }
    }

    func goUp() {
        switch location {
        case .local:
            guard let url = location.localURL else { return }
            let parent = url.deletingLastPathComponent()
            Task { await navigate(to: .local(path: parent.path)) }
        case .webDAV, .remote:
            guard let remoteLocation = try? remoteLocation(for: location), let remoteParent else { return }
            Task {
                await navigate(to: .remote(.init(
                    accountID: remoteLocation.accountID,
                    connectorID: remoteLocation.connectorID,
                    path: remoteParent
                )))
            }
        case .rclone:
            break
        }
    }

    func toggleHidden() {
        showHiddenFiles.toggle()
        Task { await refresh() }
    }

    func createFolder() {
        Task {
            do {
                switch location {
                case .local:
                    try await provider.createFolder(at: location, name: uniqueName(base: "New Folder"))
                case .webDAV, .remote:
                    let remoteLocation = try remoteLocation(for: location)
                    let remote = try await remoteProvider(for: remoteLocation)
                    try await remote.createDirectory(in: remoteLocation.path, named: "New Folder")
                case .rclone:
                    throw OpenFinderError.unsupportedLocation(location)
                }
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func createFile() {
        Task {
            do {
                switch location {
                case .local:
                    try await provider.createFile(at: location, name: uniqueName(base: "Untitled.txt"))
                case .webDAV, .remote:
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinder-empty-\(UUID().uuidString).txt")
                    FileManager.default.createFile(atPath: temp.path, contents: Data())
                    defer { try? FileManager.default.removeItem(at: temp) }
                    let remoteLocation = try remoteLocation(for: location)
                    let remote = try await remoteProvider(for: remoteLocation)
                    _ = try await remote.upload(localURL: temp, to: remoteLocation.path, named: "Untitled.txt")
                case .rclone:
                    throw OpenFinderError.unsupportedLocation(location)
                }
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func renameFirstSelected(to newName: String) {
        guard let item = selectedItems.first else { return }
        Task {
            do {
                switch item.location {
                case .local:
                    _ = try await provider.rename(item, to: newName)
                case .webDAV, .remote:
                    let itemLocation = try remoteLocation(for: item.location)
                    let destinationLocation = try remoteLocation(for: location)
                    let remote = try await remoteProvider(for: itemLocation)
                    try await remote.move(item: itemLocation.path, to: destinationLocation.path, named: newName)
                case .rclone:
                    throw OpenFinderError.unsupportedLocation(item.location)
                }
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func trashSelected() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        if selected.contains(where: { item in if case .local = item.location { return false }; return true }) {
            pendingDeletion = PendingDeletion(items: selected)
            return
        }
        delete(selected)
    }

    func confirmPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        delete(pending.items)
    }

    func cancelPendingDeletion() {
        pendingDeletion = nil
    }

    private func delete(_ selected: [FileItem]) {
        Task {
            do {
                for item in selected {
                    switch item.location {
                    case .local:
                        try await provider.trashOrDelete([item])
                    case .webDAV, .remote:
                        let remoteLocation = try remoteLocation(for: item.location)
                        let remote = try await remoteProvider(for: remoteLocation)
                        try await remote.delete(item: remoteLocation.path)
                    case .rclone:
                        throw OpenFinderError.unsupportedLocation(item.location)
                    }
                }
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func revealSelectedInFinder() {
        let urls = selectedItems.compactMap(\.localURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openSelectedInTerminal() {
        let url = selectedItems.first?.localURL ?? location.localURL
        guard let url else { return }
        TerminalService.openTerminal(at: url.hasDirectoryPath ? url : url.deletingLastPathComponent())
    }

    func quickLookSelected() {
        let items = selectedItems
        Task {
            do {
                var urls = items.compactMap(\.localURL)
                for item in items where item.localURL == nil && !item.isDirectory {
                    urls.append(try await materializeRemoteFile(item))
                }
                QuickLookBridge.preview(urls: urls)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func prepareTagEditor() async -> TagEditorContext? {
        let selected = selectedItems
        guard let scope = FileTableTagActionAvailability.commonEditableScope(for: selected) else {
            return nil
        }

        let requestLocation = location
        let generation = beginTagEditorRequest()
        guard let tagProvider = try? await tagProvider(for: requestLocation),
              isCurrentTagEditorRequest(generation, location: requestLocation)
        else {
            return nil
        }

        let context = TagEditorContext(selectedItems: selected, commonEditableScope: scope)
        let session = TagEditorSession(
            generation: generation,
            location: requestLocation,
            context: context,
            provider: tagProvider
        )
        tagEditorSession = session
        await reloadTagCatalog(for: session)
        return isCurrentTagEditorSession(session) ? context : nil
    }

    func reloadTagCatalog() async {
        guard let session = tagEditorSession,
              session.context.operationState == .idle
        else {
            return
        }
        await reloadTagCatalog(for: session)
    }

    private func reloadTagCatalog(for session: TagEditorSession) async {
        guard isCurrentTagEditorSession(session),
              session.context.operationState == .idle
        else {
            return
        }
        session.context.begin(.loadingCatalog)
        do {
            let catalog = try await session.provider.tagCatalog(for: session.location)
            guard isCurrentTagEditorSession(session) else { return }
            session.context.replaceCatalog(catalog)
        } catch {
            guard isCurrentTagEditorSession(session) else { return }
            session.context.catalogUnavailable(message: error.localizedDescription)
        }
    }

    func applyTagChanges(_ changes: FileTagChangeSet) async {
        guard let session = tagEditorSession,
              isCurrentTagEditorSession(session),
              session.context.operationState == .idle,
              session.context.canAssociateTags,
              !changes.isEmpty
        else {
            return
        }

        session.context.begin(.applyingChanges)
        let result: TagApplyResult?
        let operationError: String?
        do {
            let applied = try await session.provider.apply(changes, to: session.context.selectedItems)
            result = applied
            operationError = applied.failures.isEmpty ? nil : tagApplyErrorMessage(for: applied.failures)
        } catch {
            result = nil
            operationError = error.localizedDescription
        }

        guard isCurrentTagEditorSession(session) else { return }
        await refresh(preservingTagEditorSession: session)
        guard isCurrentTagEditorSession(session) else { return }
        session.context.refreshSelectedItems(from: items)
        session.context.completeApply(result, errorMessage: operationError)
        if let operationError {
            errorMessage = operationError
        }
    }

    func mutateTagCatalog(_ mutation: FileTagCatalogMutation) async {
        guard let session = tagEditorSession,
              isCurrentTagEditorSession(session),
              session.context.operationState == .idle,
              session.context.canManageCatalog
        else {
            return
        }

        session.context.begin(.mutatingCatalog)
        let catalog: FileTagCatalog?
        let operationError: String?
        do {
            catalog = try await session.provider.mutate(mutation, in: session.context.commonEditableScope)
            operationError = nil
        } catch {
            catalog = nil
            operationError = error.localizedDescription
        }

        guard isCurrentTagEditorSession(session) else { return }
        await refresh(preservingTagEditorSession: session)
        guard isCurrentTagEditorSession(session) else { return }
        session.context.refreshSelectedItems(from: items)
        if let catalog {
            session.context.replaceCatalog(catalog)
        }
        session.context.completeCatalogMutation(errorMessage: operationError)
        if let operationError {
            errorMessage = operationError
        }
    }


    private func listItems(at location: Location) async throws -> BrowserPaneListing {
        switch location {
        case .local:
            return .init(
                items: try await provider.list(location, options: .init(showHiddenFiles: showHiddenFiles, sort: .name(ascending: true))),
                remoteParent: nil
            )
        case .webDAV, .remote:
            let remoteLocation = try remoteLocation(for: location)
            let remote = try await remoteProvider(for: remoteLocation)
            let listing = try await remote.list(directory: remoteLocation.path)
            let fileItems = listing.items.map { remoteItem in
                FileItem(
                    id: "remote:\(remoteLocation.accountID.uuidString):\(remoteItem.remotePath.identifier)",
                    name: remoteItem.name,
                    location: .remote(.init(
                        accountID: remoteLocation.accountID,
                        connectorID: remoteLocation.connectorID,
                        path: remoteItem.remotePath
                    )),
                    kind: remoteItem.kind,
                    size: remoteItem.size,
                    modificationDate: remoteItem.modificationDate,
                    creationDate: nil,
                    uti: nil,
                    mimeType: remoteItem.mimeType,
                    fileExtension: URL(fileURLWithPath: remoteItem.name).pathExtension.isEmpty ? nil : URL(fileURLWithPath: remoteItem.name).pathExtension.lowercased(),
                    isHidden: remoteItem.name.hasPrefix("."),
                    isReadable: remoteItem.isReadable,
                    isWritable: remoteItem.isWritable,
                    tags: remoteItem.tags,
                    tagScopes: remoteItem.tagScopes,
                    supportsTagEditing: remoteItem.supportsTagEditing
                )
            }
            return .init(items: sortItems(fileItems), remoteParent: listing.parent)
        case .rclone:
            throw OpenFinderError.unsupportedLocation(location)
        }
    }

    private func refreshDirectorySizeCalculations(for listedItems: [FileItem]) {
        let currentIDs = Set(listedItems.map(\.id))
        directorySizeText = directorySizeText.filter { currentIDs.contains($0.key) }
        let obsoleteTaskIDs = directorySizeTasks.keys.filter { !currentIDs.contains($0) }
        for id in obsoleteTaskIDs {
            directorySizeTasks.removeValue(forKey: id)?.cancel()
        }

        for item in listedItems where item.isDirectory && item.localURL != nil {
            if let cached = directorySizeCache[item.id] {
                directorySizeText[item.id] = FileSizeFormatter.openFinderString(fromByteCount: cached)
                continue
            }
            if directorySizeTasks[item.id] != nil { continue }
            directorySizeText[item.id] = "计算中…"
            let id = item.id
            let location = item.location
            let provider = LocalFileProvider()
            directorySizeTasks[id] = Task { [weak self] in
                do {
                    let size = try await provider.directorySize(at: location)
                    self?.completeDirectorySize(id: id, size: size)
                } catch {
                    self?.completeDirectorySize(id: id, size: nil)
                }
            }
        }
    }

    private func completeDirectorySize(id: String, size: Int64?) {
        directorySizeTasks.removeValue(forKey: id)
        guard items.contains(where: { $0.id == id }) else { return }
        if let size {
            directorySizeCache[id] = size
            directorySizeText[id] = FileSizeFormatter.openFinderString(fromByteCount: size)
        } else {
            directorySizeText[id] = "—"
        }
    }

    private func remoteLocation(for location: Location) throws -> RemoteLocation {
        switch location {
        case .remote(let remoteLocation):
            return remoteLocation
        case .webDAV(let accountID, let path):
            return .init(
                accountID: accountID,
                connectorID: .webDAV,
                path: .init(identifier: path, displayPath: path)
            )
        case .local, .rclone:
            throw OpenFinderError.unsupportedLocation(location)
        }
    }

    private func remoteProvider(for remoteLocation: RemoteLocation) async throws -> any RemoteProvider {
        try await remoteProviderResolver(remoteLocation)
    }

    private func tagProvider(for location: Location) async throws -> (any TagProvider)? {
        switch location {
        case .local:
            return provider
        case .webDAV, .remote:
            let remoteLocation = try remoteLocation(for: location)
            let remote = try await remoteProvider(for: remoteLocation)
            return remote as? any TagProvider
        case .rclone:
            return nil
        }
    }

    private func beginTagEditorRequest() -> UInt64 {
        invalidateTagEditorSession()
        return tagEditorGeneration
    }

    private func invalidateTagEditorSession() {
        tagEditorGeneration &+= 1
        tagEditorSession?.context.deactivate()
        tagEditorSession = nil
    }

    private func isCurrentTagEditorRequest(_ generation: UInt64, location: Location) -> Bool {
        tagEditorGeneration == generation && self.location == location
    }

    private func isCurrentTagEditorSession(_ session: TagEditorSession) -> Bool {
        guard tagEditorGeneration == session.generation,
              location == session.location,
              let currentSession = tagEditorSession
        else {
            return false
        }
        return currentSession.generation == session.generation && currentSession.context === session.context
    }

    private func tagApplyErrorMessage(for failures: [TagApplyFailure]) -> String {
        failures.map { failure in
            "\(failure.itemID): \(failure.message)"
        }
        .joined(separator: "\n")
    }

    private func materializeRemoteFile(_ item: FileItem) async throws -> URL {
        let remoteLocation = try remoteLocation(for: item.location)
        let remote = try await remoteProvider(for: remoteLocation)
        try FileManager.default.createDirectory(at: remoteMaterializationDirectory, withIntermediateDirectories: true)
        let name = try safeRemoteFileName(item.name)
        let destination = remoteMaterializationDirectory.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        _ = try await remote.download(item: remoteLocation.path, to: destination)
        return destination
    }

    func downloadRemoteFile(_ item: FileItem, to destination: URL) async throws {
        guard !item.isDirectory, item.localURL == nil else {
            throw OpenFinderError.operationFailed("Only remote files can be dragged out")
        }
        _ = try safeRemoteFileName(item.name)
        let remoteLocation = try remoteLocation(for: item.location)
        let remote = try await remoteProvider(for: remoteLocation)
        _ = try await remote.download(item: remoteLocation.path, to: destination)
    }

    private func safeRemoteFileName(_ name: String) throws -> String {
        let baseName = URL(fileURLWithPath: name).lastPathComponent
        guard baseName == name,
              !name.contains("/"),
              !name.contains("\\"),
              !baseName.isEmpty,
              baseName != ".",
              baseName != ".." else {
            throw OpenFinderError.operationFailed("Remote file has an unsafe name")
        }
        return baseName
    }

    private func sortItems(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func uniqueName(base: String) -> String {
        guard let root = location.localURL else { return base }
        let ext = URL(fileURLWithPath: base).pathExtension
        let stem = ext.isEmpty ? base : String(base.dropLast(ext.count + 1))
        var candidate = base
        var index = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            index += 1
        }
        return candidate
    }
}


final class RemoteAccountDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private let storageURL: URL?
    private var storage: [UUID: RemoteAccount] = [:]

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let accounts = try? JSONDecoder.openFinder.decode([RemoteAccount].self, from: data) {
            self.storage = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        }
    }

    func save(_ account: RemoteAccount) {
        lock.lock(); defer { lock.unlock() }
        storage[account.id] = account
        persistLocked()
    }

    func account(id: UUID) -> RemoteAccount? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]
    }

    func all() -> [RemoteAccount] {
        lock.lock(); defer { lock.unlock() }
        return storage.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: id)
        persistLocked()
    }

    private func persistLocked() {
        guard let storageURL else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let accounts = storage.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            try JSONEncoder.openFinder.encode(accounts).write(to: storageURL, options: .atomic)
        } catch {
            // Persistence failure should not crash browsing; the Settings status surface reports operational failures.
        }
    }
}

enum FileTransferService {
    static func copyOrMove(_ items: [FileItem], from source: Location, to destination: Location, move: Bool, overwriteExisting: Bool = false, remoteProviderResolver: @escaping @Sendable (RemoteLocation) async throws -> any RemoteProvider, progress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        if case .local = source, case .local = destination {
            let provider = LocalFileProvider()
            if move { _ = try await provider.move(items, to: destination, overwriteExisting: overwriteExisting) }
            else { _ = try await provider.copy(items, to: destination, overwriteExisting: overwriteExisting) }
            return
        }

        if case .local = source {
            let remoteDestination = try remoteLocation(for: destination)
            let remote = try await remoteProviderResolver(remoteDestination)
            let existingItems = Dictionary(uniqueKeysWithValues: try await remote.list(directory: remoteDestination.path).items.map { ($0.name, $0) })
            for (index, item) in items.enumerated() {
                guard let url = item.localURL else { continue }
                if existingItems[item.name] != nil {
                    throw OpenFinderError.operationFailed(
                        overwriteExisting
                            ? "Replacing existing remote items is not supported yet"
                            : "Remote destination already contains: \(item.name)"
                    )
                }
                progress?(Double(index) / Double(max(items.count, 1)), "Uploading \(item.name)")
                try await upload(localURL: url, to: remoteDestination.path, remote: remote)
            }
            if move { try await LocalFileProvider().trashOrDelete(items) }
            return
        }

        if case .local = destination {
            guard let destinationURL = destination.localURL else { throw OpenFinderError.unsupportedLocation(destination) }
            let remoteSource = try remoteLocation(for: source)
            let remote = try await remoteProviderResolver(remoteSource)
            for (index, item) in items.enumerated() {
                let remoteItem = try remoteLocation(for: item.location).path
                progress?(Double(index) / Double(max(items.count, 1)), "Downloading \(item.name)")
                try await download(
                    remotePath: remoteItem,
                    kind: item.kind,
                    named: item.name,
                    to: try safeChildURL(in: destinationURL, named: item.name, isDirectory: item.isDirectory),
                    remote: remote,
                    overwriteExisting: overwriteExisting
                )
                if move { try await remote.delete(item: remoteItem) }
            }
            return
        }

        let remoteSource = try remoteLocation(for: source)
        let remoteDestination = try remoteLocation(for: destination)
        guard remoteSource.accountID == remoteDestination.accountID,
              remoteSource.connectorID == remoteDestination.connectorID else {
            throw OpenFinderError.operationFailed("Transferring directly between different remote accounts is not supported yet")
        }
        let remote = try await remoteProviderResolver(remoteSource)
        let existingNames = Set(try await remote.list(directory: remoteDestination.path).items.map(\.name))
        for (index, item) in items.enumerated() {
            if existingNames.contains(item.name) {
                throw OpenFinderError.operationFailed(
                    overwriteExisting
                        ? "Replacing existing remote items is not supported yet"
                        : "Remote destination already contains: \(item.name)"
                )
            }
            let remoteItem = try remoteLocation(for: item.location).path
            progress?(Double(index) / Double(max(items.count, 1)), "Transferring \(item.name)")
            if move { try await remote.move(item: remoteItem, to: remoteDestination.path, named: item.name) }
            else { try await remote.copy(item: remoteItem, to: remoteDestination.path, named: item.name) }
        }
    }

    private static func remoteLocation(for location: Location) throws -> RemoteLocation {
        switch location {
        case .remote(let remoteLocation):
            return remoteLocation
        case .webDAV(let accountID, let path):
            return .init(accountID: accountID, connectorID: .webDAV, path: .init(identifier: path, displayPath: path))
        case .local, .rclone:
            throw OpenFinderError.unsupportedLocation(location)
        }
    }

    private static func upload(localURL: URL, to parent: RemotePath, remote: any RemoteProvider) async throws {
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            let name = localURL.lastPathComponent
            try await remote.createDirectory(in: parent, named: name)
            let listing = try await remote.list(directory: parent)
            guard let created = listing.items.first(where: { $0.name == name && $0.kind == .directory }) else {
                throw OpenFinderError.operationFailed("Remote directory was not visible after creation: \(name)")
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: localURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for child in children {
                try await upload(localURL: child, to: created.remotePath, remote: remote)
            }
        } else {
            _ = try await remote.upload(localURL: localURL, to: parent, named: localURL.lastPathComponent)
        }
    }

    private static func download(
        remotePath: RemotePath,
        kind: FileKind,
        named name: String,
        to destination: URL,
        remote: any RemoteProvider,
        overwriteExisting: Bool
    ) async throws {
        let fileManager = FileManager.default
        if kind == .directory || kind == .package {
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw OpenFinderError.operationFailed("Replacing existing local directories is not supported yet")
            }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let listing = try await remote.list(directory: remotePath)
            for child in listing.items {
                try await download(
                    remotePath: child.remotePath,
                    kind: child.kind,
                    named: child.name,
                    to: try safeChildURL(
                        in: destination,
                        named: child.name,
                        isDirectory: child.kind == .directory || child.kind == .package
                    ),
                    remote: remote,
                    overwriteExisting: false
                )
            }
        } else {
            if !fileManager.fileExists(atPath: destination.path) {
                _ = try await remote.download(item: remotePath, to: destination)
                return
            }
            guard overwriteExisting else {
                throw OpenFinderError.operationFailed("Local destination already contains: \(name)")
            }
            let staged = destination.deletingLastPathComponent()
                .appendingPathComponent(".openfinder-remote-replace-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: staged) }
            _ = try await remote.download(item: remotePath, to: staged)
            try fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    private static func safeChildURL(in parent: URL, named name: String, isDirectory: Bool) throws -> URL {
        let baseName = URL(fileURLWithPath: name).lastPathComponent
        guard baseName == name,
              !name.contains("/"),
              !name.contains("\\"),
              !baseName.isEmpty,
              baseName != ".",
              baseName != ".." else {
            throw OpenFinderError.operationFailed("Remote item has an unsafe name")
        }
        return parent.appendingPathComponent(baseName, isDirectory: isDirectory)
    }
}
