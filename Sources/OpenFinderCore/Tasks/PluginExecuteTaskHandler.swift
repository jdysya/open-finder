import Foundation

public enum PluginTaskResolutionError: Error, Equatable, Sendable {
    case pluginUnavailable(String)
    case versionUnavailable(pluginID: String, version: String)
}

public struct PluginTaskPluginResolver: Sendable {
    public typealias Operation = @Sendable (
        _ pluginID: String,
        _ pluginVersion: String
    ) async throws -> LoadedPlugin

    private let operation: Operation

    public init(_ operation: @escaping Operation) {
        self.operation = operation
    }

    public func resolve(pluginID: String, pluginVersion: String) async throws -> LoadedPlugin {
        try await operation(pluginID, pluginVersion)
    }

    public static func exact(_ plugins: [LoadedPlugin]) -> Self {
        Self { pluginID, pluginVersion in
            let candidates = plugins.filter { $0.id == pluginID }
            guard !candidates.isEmpty else {
                throw PluginTaskResolutionError.pluginUnavailable(pluginID)
            }
            let exactMatches = candidates.filter {
                $0.manifest.version == pluginVersion
            }
            guard exactMatches.count == 1, let plugin = exactMatches.first else {
                throw PluginTaskResolutionError.versionUnavailable(
                    pluginID: pluginID,
                    version: pluginVersion
                )
            }
            return plugin
        }
    }
}

public struct PluginExecuteTaskHandler: Sendable {
    private let pluginResolver: PluginTaskPluginResolver
    private let credentialResolver: PluginCredentialResolver
    private let coordinator: PluginExecutionCoordinator
    private let publish: @Sendable (UUID, PluginResultProjection) async throws -> Void
    private let cleanupWarning: @Sendable (TaskEventSink) async -> Void

    public init(
        pluginResolver: PluginTaskPluginResolver,
        credentialResolver: PluginCredentialResolver,
        coordinator: PluginExecutionCoordinator,
        publish: @escaping @Sendable (
            UUID,
            PluginResultProjection
        ) async throws -> Void = { _, _ in },
        cleanupWarning: @escaping @Sendable (TaskEventSink) async -> Void = { _ in }
    ) {
        self.pluginResolver = pluginResolver
        self.credentialResolver = credentialResolver
        self.coordinator = coordinator
        self.publish = publish
        self.cleanupWarning = cleanupWarning
    }

    public var taskHandler: TaskHandler {
        TaskHandler(
            handlerID: DurableTaskHandlerID.pluginExecute.rawValue,
            payloadVersion: 1
        ) { descriptor, events in
            try await execute(descriptor: descriptor, events: events)
        }
    }

    public func makeTaskHandler() -> TaskHandler {
        taskHandler
    }

    public func execute(
        descriptor: TaskDescriptorEnvelope,
        events: TaskEventSink
    ) async throws -> TaskResult {
        let payload: PluginTaskEnvelope
        do {
            payload = try PluginTaskEnvelope.decode(from: descriptor)
        } catch {
            throw TaskHandlerRegistryError.handlerUnavailable(
                "plugin task descriptor: \(error.localizedDescription)"
            )
        }
        let plugin: LoadedPlugin
        do {
            plugin = try await pluginResolver.resolve(
                pluginID: payload.pluginID,
                pluginVersion: payload.pluginVersion
            )
        } catch {
            throw TaskHandlerRegistryError.handlerUnavailable(
                "plugin \(payload.pluginID) version \(payload.pluginVersion)"
            )
        }
        guard let action = plugin.manifest.actions.first(where: {
            $0.id == payload.actionID
        }) else {
            throw TaskHandlerRegistryError.handlerUnavailable(
                "plugin action \(payload.pluginID)/\(payload.actionID)"
            )
        }
        guard action.output?.resultSchemaID ?? "unknown" == payload.resultSchemaID,
              action.output?.canCopyToClipboard ?? false
                == payload.outputPolicy.canCopyToClipboard else {
            throw TaskHandlerRegistryError.handlerUnavailable(
                "plugin action snapshot \(payload.pluginID)/\(payload.actionID)"
            )
        }
        try verifyConfiguration(payload, manifest: plugin.manifest)
        try verifyCredentials(payload, manifest: plugin.manifest)

        let request = PluginExecutionRequest(
            plugin: plugin,
            pluginVersion: payload.pluginVersion,
            action: action,
            taskID: descriptor.taskID,
            app: .init(name: payload.app.name, version: payload.app.version),
            context: .init(
                activePane: payload.context.activePane,
                currentLocation: payload.context.currentLocation
            ),
            files: payload.inputs.map(\.pluginInputFile),
            configurationValues: payload.configuration,
            secretReferences: payload.secretReferences
        )
        let outcome: PluginExecutionOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await coordinator.execute(
                    request,
                    callbacks: callbacks(taskID: descriptor.taskID, events: events)
                )
            } onCancel: {
                Task { await coordinator.cancel(taskID: descriptor.taskID) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PluginExecutionCoordinatorError {
            switch error {
            case .pluginVersionMismatch, .actionMismatch, .connectionUnavailable,
                 .connectionPluginMismatch, .connectionVersionMismatch:
                throw TaskHandlerRegistryError.handlerUnavailable(error.localizedDescription)
            case .nonzeroExit, .invalidTerminalResult, .terminalFailure:
                throw OpenFinderError.operationFailed("Plugin execution failed.")
            }
        } catch {
            throw OpenFinderError.operationFailed("Plugin execution failed.")
        }
        if case .http = plugin.manifest.execution {
            _ = await events.appendLog(HTTPPluginTranscript.resultCommitted(
                taskID: descriptor.taskID,
                pluginID: plugin.id,
                actionID: action.id,
                schema: payload.resultSchemaID
            ).message)
        }
        return .success(
            summary: outcome.summary,
            clipboard: payload.outputPolicy.canCopyToClipboard ? outcome.clipboard : nil
        )
    }

    private func verifyConfiguration(
        _ payload: PluginTaskEnvelope,
        manifest: PluginManifest
    ) throws {
        let allowed = Set(manifest.configuration.map(\.key))
        guard Set(payload.configuration.keys).isSubset(of: allowed) else {
            throw TaskHandlerRegistryError.handlerUnavailable(
                "plugin configuration \(payload.pluginID)"
            )
        }
        let secretKeys = Set(manifest.permissions.secretKeys)
        guard Set(payload.configuration.keys).isDisjoint(with: secretKeys),
              Set(payload.secretReferences.keys).isSubset(of: secretKeys) else {
            throw TaskHandlerRegistryError.handlerUnavailable(
                "plugin credential declaration \(payload.pluginID)"
            )
        }
        if case .http(_, _, let tokenSecretKey) = manifest.execution,
           payload.secretReferences[tokenSecretKey] == nil {
            throw TaskHandlerRegistryError.handlerUnavailable(
                "plugin credential \(payload.pluginID)/\(tokenSecretKey)"
            )
        }
    }

    private func verifyCredentials(
        _ payload: PluginTaskEnvelope,
        manifest: PluginManifest
    ) throws {
        for key in manifest.permissions.secretKeys {
            guard let reference = payload.secretReferences[key] else { continue }
            let value: String?
            do {
                value = try credentialResolver.secret(for: reference)
            } catch {
                throw TaskHandlerRegistryError.handlerUnavailable(
                    "plugin credential \(payload.pluginID)/\(key)"
                )
            }
            guard let value, !value.isEmpty else {
                throw TaskHandlerRegistryError.handlerUnavailable(
                    "plugin credential \(payload.pluginID)/\(key)"
                )
            }
        }
    }

    private func callbacks(
        taskID: UUID,
        events: TaskEventSink
    ) -> PluginExecutionCallbacks {
        PluginExecutionCallbacks(
            onEvent: { event in
                switch event {
                case .progress(let progress):
                    Task {
                        _ = await events.updateProgress(.init(
                            fraction: progress.fraction,
                            phase: progress.phase,
                            detail: progress.message,
                            completed: progress.completed,
                            total: progress.total,
                            unit: progress.unit
                        ))
                    }
                case .log(let level, let message):
                    Task { _ = await events.appendLog(message, level: level) }
                case .result(_, let message, _, _):
                    if let message {
                        Task { _ = await events.appendLog(message) }
                    }
                }
            },
            onHTTPTranscript: { transcript in
                _ = await events.appendLog(transcript.message)
            },
            publish: { projection in
                try await publish(taskID, projection)
            },
            markEffectsCommitted: {
                try await events.markEffectsCommitted()
            },
            cleanupWarning: {
                await cleanupWarning(events)
            }
        )
    }
}
