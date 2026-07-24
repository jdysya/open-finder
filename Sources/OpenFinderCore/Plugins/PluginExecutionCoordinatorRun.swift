import Foundation

extension PluginExecutionCoordinator {
    func run(
        _ request: PluginExecutionRequest,
        config: [String: String],
        credentials: (references: [String: PluginSecretReference], environment: [String: String]),
        workspace: PluginExecutionWorkspace,
        callbacks: PluginExecutionCallbacks
    ) async throws -> PluginExecutionOutcome {
        let input = PluginInput(
            schemaVersion: 1,
            taskID: request.taskID,
            actionID: request.action.id,
            app: request.app,
            context: request.context,
            files: request.files,
            config: config,
            secrets: credentials.references,
            tempDirectory: workspace.tempDirectory.path,
            outputDirectory: workspace.outputDirectory.path
        )
        let result = try await runner.run(.init(
            manifest: request.plugin.manifest,
            action: request.action,
            input: input,
            environment: credentials.environment,
            pluginDirectory: request.plugin.directory,
            workingDirectory: request.plugin.directory,
            onEvent: callbacks.onEvent
        ))
        try validateTerminal(result)
        let schemaID = request.action.output?.resultSchemaID ?? "unknown"
        let context = PluginResultHandlingContext(
            resultSchemaID: schemaID,
            pluginID: request.plugin.id,
            pluginVersion: request.pluginVersion,
            actionID: request.action.id,
            taskID: request.taskID,
            events: result.events,
            outputDirectory: workspace.outputDirectory
        )
        let committed = try await artifactCommit.commit(context, workspace: workspace)
        let projection = try await resultHandlers.handle(committed)
        try await callbacks.publish(projection)
        return .init(
            summary: result.events.compactMap(\.resultMessage).last ?? "Plugin completed",
            clipboard: result.events.compactMap(\.clipboardText).last,
            projection: projection
        )
    }

    private func validateTerminal(_ result: PluginRunResult) throws {
        guard result.exitCode == 0 else {
            throw PluginExecutionCoordinatorError.nonzeroExit(result.exitCode, result.stderr)
        }
        let terminalIndexes = result.events.indices.filter {
            result.events[$0].resultStatus != nil
        }
        guard terminalIndexes.count == 1, terminalIndexes.first == result.events.indices.last else {
            throw PluginExecutionCoordinatorError.invalidTerminalResult
        }
        guard let terminal = result.events.last else {
            throw PluginExecutionCoordinatorError.invalidTerminalResult
        }
        switch terminal.resultStatus {
        case "success":
            return
        case "failure":
            throw PluginExecutionCoordinatorError.terminalFailure(
                terminal.resultMessage ?? "Plugin reported failure."
            )
        case "cancelled":
            throw CancellationError()
        default:
            throw PluginExecutionCoordinatorError.invalidTerminalResult
        }
    }
}

public extension PluginActionOutput {
    var resultSchemaID: String? { resultType }
}
