import Foundation
import OpenFinderCore

extension AppModel {
    func runPlugin(
        _ plugin: LoadedPlugin,
        action: PluginActionManifest,
        items: [FileItem],
        pane: BrowserPaneModel
    ) {
        Task {
            let resolvedConfiguration = PluginConfigurationResolver.resolve(
                manifest: plugin.manifest,
                values: configuration.pluginConfigurationValues[plugin.id] ?? [:],
                secretReferences: configuredPluginSecretReferences(for: plugin.manifest)
            )
            do {
                if case .http = plugin.manifest.execution {
                    let connection = await checkPluginConnection(plugin)
                    guard connection.canSubmit else {
                        statusMessage = connection.guidance
                        return
                    }
                }
                let isVideoAnalysis = plugin.id == Self.videoAnalyzerPluginID
                    && action.id == Self.videoAnalyzerActionID
                let analysisBox = VideoAnalysisResultBox()
                let currentLocation = pane.location
                let paneID = pane.id.rawValue
                let runner = pluginRunnerRouter
                let credentialResolver = pluginCredentialResolver
                let analysisStore = videoAnalysisStore
                let workspaceMaintenance = pluginWorkspaceMaintenance
                let queuedID = try await taskQueue.enqueue(.init(
                    kind: isVideoAnalysis ? .videoAnalysis : .plugin(
                        pluginID: plugin.id,
                        actionID: action.id
                    ),
                    title: "\(plugin.manifest.name): \(action.title)",
                    resourceKey: isVideoAnalysis ? Self.videoAnalyzerResourceKey : nil
                ) { context in
                    let invocationCredentials = try Self.prepareInvocationCredentials(
                        execution: plugin.manifest.execution,
                        secrets: resolvedConfiguration.secrets,
                        credentialResolver: credentialResolver
                    )
                    return try await Self.withTaskWorkspace(
                        execution: plugin.manifest.execution,
                        taskID: context.id,
                        currentLocation: currentLocation,
                        maintenance: workspaceMaintenance,
                        context: context
                    ) { workspace in
                        let input = PluginInput(
                            schemaVersion: 1,
                            taskID: context.id,
                            actionID: action.id,
                            app: .init(name: "OpenFinder", version: "0.1.0"),
                            context: .init(activePane: paneID, currentLocation: currentLocation),
                            files: items.map(PluginInputFile.init(item:)),
                            config: resolvedConfiguration.config,
                            secrets: invocationCredentials.references,
                            tempDirectory: workspace.tempDirectory.path,
                            outputDirectory: workspace.outputDirectory.path
                        )
                        await context.appendLog("Starting plugin \(plugin.manifest.name) / \(action.title)")
                        let result = try await runner.run(.init(
                            manifest: plugin.manifest,
                            action: action,
                            input: input,
                            environment: invocationCredentials.environment,
                            pluginDirectory: plugin.directory,
                            workingDirectory: plugin.directory,
                            onEvent: { event in
                                Task {
                                    switch event {
                                    case .log(let level, let message):
                                        await context.appendLog(message, level: level)
                                    case .progress(let progress):
                                        await context.updateProgress(.init(
                                            fraction: progress.fraction,
                                            phase: progress.phase,
                                            detail: progress.message,
                                            completed: progress.completed,
                                            total: progress.total,
                                            unit: progress.unit
                                        ))
                                    case .result(_, let message, _, _):
                                        if let message { await context.appendLog(message) }
                                    }
                                }
                            }
                        ))
                        if result.exitCode != 0 {
                            throw OpenFinderError.operationFailed(
                                result.stderr.isEmpty ? "Plugin exited with \(result.exitCode)" : result.stderr
                            )
                        }
                        if let terminal = result.events.last(where: { $0.resultStatus != nil }) {
                            switch terminal.resultStatus {
                            case "failure":
                                throw OpenFinderError.operationFailed(
                                    terminal.resultMessage ?? "Plugin reported failure"
                                )
                            case "cancelled":
                                throw CancellationError()
                            default:
                                break
                            }
                        }
                        if isVideoAnalysis {
                            let durable = try await Self.persistVideoAnalysis(
                                events: result.events,
                                taskID: context.id,
                                workspace: workspace,
                                execution: plugin.manifest.execution,
                                store: analysisStore
                            )
                            await analysisBox.store(durable)
                        }
                        let message = result.events.compactMap { event in
                            if case .result(_, let message, _, _) = event { return message }
                            return nil
                        }.last ?? "Plugin completed"
                        return .success(
                            summary: message,
                            clipboard: result.events.compactMap(\.clipboardText).last
                        )
                    }
                })
                statusMessage = "Queued plugin task \(queuedID.uuidString.prefix(8))"
                await observeTask(queuedID)
                if let analysis = await analysisBox.value {
                    await cacheVideoAnalysis(analysis, analyzerVersion: Self.videoAnalyzerVersion)
                    presentedVideoAnalysis = analysis
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    nonisolated private static func prepareInvocationCredentials(
        execution: PluginExecution,
        secrets: [String: PluginSecretReference],
        credentialResolver: PluginCredentialResolver
    ) throws -> (references: [String: PluginSecretReference], environment: [String: String]) {
        guard case .process = execution else { return (secrets, [:]) }

        var references: [String: PluginSecretReference] = [:]
        var environment: [String: String] = [:]
        for (index, pair) in secrets.sorted(by: { $0.key < $1.key }).enumerated() {
            let (logicalKey, reference) = pair
            guard let secret = try credentialResolver.secret(for: reference.env), !secret.isEmpty else {
                throw OpenFinderError.missingSecret(logicalKey)
            }
            let suffix = logicalKey.uppercased().map { character in
                character.isASCII && (character.isLetter || character.isNumber) ? character : "_"
            }
            let environmentKey = "OPENFINDER_SECRET_\(index)_\(String(suffix))"
            references[logicalKey] = PluginSecretReference(env: environmentKey)
            environment[environmentKey] = secret
        }
        return (references, environment)
    }

    nonisolated private static func workspace(
        execution: PluginExecution,
        taskID: UUID,
        currentLocation: Location
    ) -> PluginWorkspace {
        if case .http = execution { return .makeHTTP(taskID: taskID) }
        return .make(taskID: taskID, currentLocation: currentLocation)
    }

    nonisolated private static func withTaskWorkspace<Value>(
        execution: PluginExecution,
        taskID: UUID,
        currentLocation: Location,
        maintenance: PluginWorkspaceMaintenance,
        context: TaskExecutionContext,
        operation: (PluginWorkspace) async throws -> Value
    ) async throws -> Value {
        let workspace = workspace(execution: execution, taskID: taskID, currentLocation: currentLocation)
        let outcome: Result<Value, Error>
        do {
            try FileManager.default.createDirectory(at: workspace.tempDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace.outputDirectory, withIntermediateDirectories: true)
            outcome = .success(try await operation(workspace))
        } catch {
            outcome = .failure(error)
        }
        do {
            try maintenance.cleanup(workspace)
        } catch {
            await maintenance.reportFailure(context)
        }
        return try outcome.get()
    }

    nonisolated private static func persistVideoAnalysis(
        events: [PluginOutputEvent],
        taskID: UUID,
        workspace: PluginWorkspace,
        execution: PluginExecution,
        store: VideoAnalysisResultStore
    ) async throws -> VideoAnalysisResult {
        switch execution {
        case .http:
            let result = try VideoAnalysisPluginResultDecoder.decode(
                from: events,
                expectedTaskID: taskID,
                expectedOutputDirectory: workspace.outputDirectory
            )
            let reader = try ConfinedArtifactReader(root: workspace.outputDirectory)
            return try await store.persistConfinedAssets(in: result, from: reader)
        case .process:
            let result = try VideoAnalysisPluginResultDecoder.decode(
                from: events,
                expectedTaskID: taskID
            )
            return try await store.persistAssets(in: result)
        }
    }
}
