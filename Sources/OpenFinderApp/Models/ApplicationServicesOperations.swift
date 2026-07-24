import Foundation
import OpenFinderCore

enum PresentedPluginResultAction: Sendable {
    case applyMediaAnalysisTags(
        document: MediaAnalysisDocument,
        selections: [MediaAnalysisTagSelection],
        managedTagsByMedia: [String: Set<String>]
    )
}

struct PresentedPluginResultActionOutcome: Sendable {
    let message: String
    let managedTagsByMedia: [String: Set<String>]
}

@MainActor
extension ApplicationServices {
    func prepareDurableExecution() async throws {
        if let databaseOpenError {
            throw databaseOpenError
        }
        let composition = try compositionResult.get()
        let registry = try await composition.makeTaskHandlerRegistry()
        try await taskService.installHandlerRegistry(registry)
        if let recoveryStore {
            try await taskService.recoverPersistedTasks(from: recoveryStore)
        }
    }

    func attachReadiness(_ task: Task<Result<Void, any Error>, Never>) {
        taskService.attachReadinessTask(task)
    }

    func requireDurableReadiness() async throws {
        try await taskService.requireReadiness()
    }

    func resumeRecoveredWork() async {
        await taskService.resumeRecoveredTasks()
    }

    func taskProjection() async -> TaskApplicationProjection {
        await taskService.projection()
    }

    func cancelTask(_ id: UUID) async -> TaskApplicationProjection {
        await taskService.cancel(id)
    }

    func retryTask(_ id: UUID) async throws -> (UUID, TaskApplicationProjection) {
        try await taskService.retry(id)
    }

    func awaitTask(
        _ id: UUID,
        timeout: TimeInterval
    ) async throws -> (TaskRecord, TaskApplicationProjection) {
        try await taskService.waitForTerminalStatus(id, timeout: timeout)
    }

    func startTaskObservation(
        publish: @escaping @MainActor (TaskApplicationProjection) -> Void
    ) {
        taskService.startPolling(publish: publish)
    }

    func loadConfiguration() async throws -> AppConfiguration {
        try await configurationService.load()
    }

    func publish(configuration: AppConfiguration) {
        configurationService.publish(configuration)
        pluginService.publish(configuration: configuration)
    }

    func saveConfiguration() {
        configurationService.saveCurrent()
    }

    func flushConfigurationSaves() async {
        await configurationService.flush()
    }

    func scanPlugins() -> PluginScanResult {
        let projectPlugins = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ExamplePlugins", isDirectory: true)
        let bundledPlugins = Bundle.main.resourceURL?
            .appendingPathComponent("BuiltinPlugins", isDirectory: true)
        let appSupportPlugins = Self.applicationSupportDirectory()
            .appendingPathComponent("Plugins", isDirectory: true)
        let locations: [(URL, PluginSource)] = [
            (projectPlugins, .development),
            (appSupportPlugins, .user),
        ] + (bundledPlugins.map { [($0, .builtIn)] } ?? [])
        return pluginService.scan(locations: locations)
    }

    func registerPlugins(_ plugins: [LoadedPlugin]) async {
        await pluginResolver.register(plugins)
    }

    func pluginActions(
        in plugins: [LoadedPlugin],
        for items: [FileItem]
    ) -> [(LoadedPlugin, PluginActionManifest)] {
        plugins.flatMap { plugin in
            PluginMatcher.actions(in: plugin.manifest, matching: items).map { (plugin, $0) }
        }
    }

    func checkPluginConnection(
        _ plugin: LoadedPlugin,
        configuration: AppConfiguration
    ) async -> PluginConnectionStatus {
        await pluginService.checkConnection(plugin, configuration: configuration)
    }

    func pluginSecretConfigured(
        pluginID: String,
        key: String,
        manifest: PluginManifest?
    ) -> Bool {
        pluginService.isSecretConfigured(
            pluginID: pluginID,
            key: key,
            manifest: manifest
        )
    }

    func setPluginSecret(
        _ secret: String,
        pluginID: String,
        key: String
    ) async -> PluginSecretMutationResult {
        await pluginService.setSecret(
            secret,
            pluginID: pluginID,
            key: key,
            storage: .keychain
        )
    }

    func setPluginSecret(
        _ secret: String,
        manifest: PluginManifest,
        key: String
    ) async -> PluginSecretMutationResult {
        await pluginService.setSecret(secret, manifest: manifest, key: key)
    }

    func configuredPluginSecretReferences(for manifest: PluginManifest) -> [String: String] {
        pluginService.configuredSecretReferences(for: manifest)
    }

    var remoteConnectors: [RemoteConnector] {
        accountService.connectors
    }

    func remoteAccounts() -> [RemoteAccount] {
        accountService.accounts()
    }

    func addRemoteAccount(
        connectorID: RemoteConnectorID,
        name: String,
        endpoint: String,
        username: String,
        password: String,
        allowInsecureHTTP: Bool
    ) throws -> RemoteAccountMutation {
        try accountService.addAccount(
            connectorID: connectorID,
            name: name,
            endpoint: endpoint,
            username: username,
            password: password,
            allowInsecureHTTP: allowInsecureHTTP
        )
    }

    func removeRemoteAccount(_ account: RemoteAccount) async throws -> RemoteAccountMutation {
        try await accountService.removeAccount(account)
    }

    func remoteRoot(for account: RemoteAccount) throws -> Location {
        try accountService.rootLocation(for: account)
    }

    func submitTransfer(
        _ items: [FileItem],
        source: Location,
        destination: Location,
        move: Bool,
        overwriteExisting: Bool,
        title: String
    ) async throws -> UUID {
        try await browserService.submitTransfer(
            items,
            source: source,
            destination: destination,
            move: move,
            overwriteExisting: overwriteExisting,
            title: title
        )
    }

    func normalizedLocation(_ location: Location) throws -> Location {
        try browserService.normalizedLocation(location)
    }

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
            configuration: configuration.pluginConfigurationValues[plugin.id] ?? [:],
            secretReferences: configuredPluginSecretReferences(for: plugin.manifest),
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

    func renderer(for projection: PluginResultProjection) -> PluginRendererDescriptor {
        rendererCatalog.renderer(for: projection)
    }

    func artifactURL(for id: UUID) async -> URL? {
        guard let artifactResults else { return nil }
        return try? await artifactResults.fileURL(for: id)
    }

    func perform(
        _ action: PresentedPluginResultAction
    ) async -> PresentedPluginResultActionOutcome {
        switch action {
        case .applyMediaAnalysisTags(let document, let selections, let managedTagsByMedia):
            return await applyMediaAnalysisTags(
                document: document,
                selections: selections,
                managedTagsByMedia: managedTagsByMedia
            )
        }
    }
}

private extension ApplicationServices {
    func applyMediaAnalysisTags(
        document: MediaAnalysisDocument,
        selections: [MediaAnalysisTagSelection],
        managedTagsByMedia initialManagedTagsByMedia: [String: Set<String>]
    ) async -> PresentedPluginResultActionOutcome {
        let provider = LocalFileProvider()
        let ledger = MediaAnalysisTagLedgerService()
        let selections = Dictionary(
            uniqueKeysWithValues: selections.map { ($0.stableMediaID, $0.selectedNames) }
        )
        var applied = 0
        var failures: [String] = []
        var managedTagsByMedia = initialManagedTagsByMedia
        for item in document.items {
            do {
                let file = try await provider.stat(.local(path: item.media.sourcePath))
                let update = ledger.update(
                    ledger: ManagedTagLedger(mediaEntries: managedTagsByMedia.map {
                        .init(stableMediaID: $0.key, tagNames: $0.value)
                    }),
                    item: item,
                    currentTags: file.tags,
                    selectedNames: selections[item.media.stableID, default: []]
                )
                let outcome = try await provider.apply(update.changes, to: [file])
                if let failure = outcome.failures.first {
                    failures.append("\(item.media.displayName): \(failure.message)")
                } else {
                    managedTagsByMedia[item.media.stableID] = update.nextManagedTagNames
                    applied += 1
                }
            } catch {
                failures.append("\(item.media.displayName): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            return .init(
                message: "已将所选标签应用到 \(applied) 个媒体文件。",
                managedTagsByMedia: managedTagsByMedia
            )
        }
        return .init(
            message: "已更新 \(applied) 个媒体文件。\(failures.joined(separator: " "))",
            managedTagsByMedia: managedTagsByMedia
        )
    }
}
