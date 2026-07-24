import Foundation

public enum PluginExecutionCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case pluginVersionMismatch(expected: String, actual: String)
    case actionMismatch(String)
    case connectionUnavailable(String)
    case connectionPluginMismatch(expected: String, actual: String)
    case connectionVersionMismatch(expected: String, actual: String)
    case nonzeroExit(Int32, String)
    case invalidTerminalResult
    case terminalFailure(String)

    public var errorDescription: String? {
        switch self {
        case .pluginVersionMismatch(let expected, let actual):
            "Expected plugin version \(expected), found \(actual)."
        case .actionMismatch(let actionID):
            "Plugin action snapshot no longer matches \(actionID)."
        case .connectionUnavailable(let guidance):
            guidance
        case .connectionPluginMismatch(let expected, let actual):
            "Expected plugin \(expected), connected to \(actual)."
        case .connectionVersionMismatch(let expected, let actual):
            "Expected plugin version \(expected), connected to \(actual)."
        case .nonzeroExit(let code, let message):
            message.isEmpty ? "Plugin exited with \(code)." : message
        case .invalidTerminalResult:
            "Plugin output must end with exactly one terminal result."
        case .terminalFailure(let message):
            message
        }
    }
}

public struct PluginExecutionRequest: Sendable {
    public let plugin: LoadedPlugin
    public let pluginVersion: String
    public let action: PluginActionManifest
    public let taskID: UUID
    public let app: PluginInput.AppInfo
    public let context: PluginInput.Context
    public let files: [PluginInputFile]
    public let configurationValues: [String: String]
    public let secretReferences: [String: String]

    public init(
        plugin: LoadedPlugin,
        pluginVersion: String,
        action: PluginActionManifest,
        taskID: UUID,
        app: PluginInput.AppInfo,
        context: PluginInput.Context,
        files: [PluginInputFile],
        configurationValues: [String: String],
        secretReferences: [String: String]
    ) {
        self.plugin = plugin
        self.pluginVersion = pluginVersion
        self.action = action
        self.taskID = taskID
        self.app = app
        self.context = context
        self.files = files
        self.configurationValues = configurationValues
        self.secretReferences = secretReferences
    }
}

public struct PluginExecutionCallbacks: Sendable {
    public let onEvent: @Sendable (PluginOutputEvent) -> Void
    public let publish: @Sendable (PluginResultProjection) async throws -> Void
    public let markEffectsCommitted: @Sendable () async throws -> Void
    public let cleanupWarning: @Sendable () async -> Void

    public init(
        onEvent: @escaping @Sendable (PluginOutputEvent) -> Void = { _ in },
        publish: @escaping @Sendable (PluginResultProjection) async throws -> Void = { _ in },
        markEffectsCommitted: @escaping @Sendable () async throws -> Void = {},
        cleanupWarning: @escaping @Sendable () async -> Void = {}
    ) {
        self.onEvent = onEvent
        self.publish = publish
        self.markEffectsCommitted = markEffectsCommitted
        self.cleanupWarning = cleanupWarning
    }
}

public struct PluginExecutionOutcome: Sendable {
    public let summary: String
    public let clipboard: String?
    public let projection: PluginResultProjection

    public init(summary: String, clipboard: String?, projection: PluginResultProjection) {
        self.summary = summary
        self.clipboard = clipboard
        self.projection = projection
    }
}

public struct PluginExecutionArtifactCommit: Sendable {
    public typealias Operation = @Sendable (
        PluginResultHandlingContext,
        PluginExecutionWorkspace,
        @escaping ArtifactCommitCoordinator.CommitEffects
    ) async throws -> PluginResultHandlingContext

    private let operation: Operation

    public init(_ operation: @escaping Operation) {
        self.operation = operation
    }

    public func commit(
        _ context: PluginResultHandlingContext,
        workspace: PluginExecutionWorkspace,
        markEffectsCommitted: @escaping ArtifactCommitCoordinator.CommitEffects
    ) async throws -> PluginResultHandlingContext {
        try await operation(context, workspace, markEffectsCommitted)
    }

    public static let passthrough = PluginExecutionArtifactCommit { context, _, _ in context }
}

public struct PluginExecutionCoordinator: Sendable {
    let runner: any PluginRunner
    private let connectionChecker: any PluginConnectionChecking
    private let credentialResolver: PluginCredentialResolver
    let resultHandlers: PluginResultHandlerRegistry
    let artifactCommit: PluginExecutionArtifactCommit
    private let temporaryDirectory: URL
    private let workspaceMaintenance: PluginExecutionWorkspaceMaintenance

    public init(
        runner: any PluginRunner,
        connectionChecker: any PluginConnectionChecking,
        credentialResolver: PluginCredentialResolver,
        resultHandlers: PluginResultHandlerRegistry = .standard,
        artifactCommit: PluginExecutionArtifactCommit = .passthrough,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        workspaceMaintenance: PluginExecutionWorkspaceMaintenance = .live
    ) {
        self.runner = runner
        self.connectionChecker = connectionChecker
        self.credentialResolver = credentialResolver
        self.resultHandlers = resultHandlers
        self.artifactCommit = artifactCommit
        self.temporaryDirectory = temporaryDirectory
        self.workspaceMaintenance = workspaceMaintenance
    }

    public func execute(
        _ request: PluginExecutionRequest,
        callbacks: PluginExecutionCallbacks = .init()
    ) async throws -> PluginExecutionOutcome {
        try validateIdentity(request)
        let resolved = PluginConfigurationResolver.resolve(
            manifest: request.plugin.manifest,
            values: request.configurationValues,
            secretReferences: request.secretReferences
        )
        try await validateConnection(request, resolved: resolved)
        let credentials = try invocationCredentials(
            execution: request.plugin.manifest.execution,
            secrets: resolved.secrets
        )
        let workspace = PluginExecutionWorkspace.make(
            execution: request.plugin.manifest.execution,
            taskID: request.taskID,
            currentLocation: request.context.currentLocation,
            temporaryDirectory: temporaryDirectory
        )
        let outcome: Result<PluginExecutionOutcome, Error>
        do {
            try workspace.createDirectories()
            outcome = .success(try await run(
                request,
                config: resolved.config,
                credentials: credentials,
                workspace: workspace,
                callbacks: callbacks
            ))
        } catch {
            outcome = .failure(error)
        }
        do {
            try workspaceMaintenance.cleanup(workspace)
        } catch {
            await callbacks.cleanupWarning()
        }
        return try outcome.get()
    }

    public func cancel(taskID: UUID) async {
        await runner.cancel(taskID: taskID)
    }

    private func validateIdentity(_ request: PluginExecutionRequest) throws {
        guard request.plugin.manifest.version == request.pluginVersion else {
            throw PluginExecutionCoordinatorError.pluginVersionMismatch(
                expected: request.pluginVersion,
                actual: request.plugin.manifest.version
            )
        }
        guard request.plugin.manifest.actions.contains(request.action) else {
            throw PluginExecutionCoordinatorError.actionMismatch(request.action.id)
        }
    }

    private func validateConnection(
        _ request: PluginExecutionRequest,
        resolved: ResolvedPluginConfiguration
    ) async throws {
        guard case .http = request.plugin.manifest.execution else { return }
        let status = await connectionChecker.check(
            manifest: request.plugin.manifest,
            values: resolved.config,
            secretReferences: request.secretReferences
        )
        guard status.canSubmit else {
            throw PluginExecutionCoordinatorError.connectionUnavailable(status.guidance)
        }
        if let actual = status.pluginID, actual != request.plugin.id {
            throw PluginExecutionCoordinatorError.connectionPluginMismatch(
                expected: request.plugin.id,
                actual: actual
            )
        }
        if let actual = status.pluginVersion, actual != request.pluginVersion {
            throw PluginExecutionCoordinatorError.connectionVersionMismatch(
                expected: request.pluginVersion,
                actual: actual
            )
        }
    }

    private func invocationCredentials(
        execution: PluginExecution,
        secrets: [String: PluginSecretReference]
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
            references[logicalKey] = .init(env: environmentKey)
            environment[environmentKey] = secret
        }
        return (references, environment)
    }
}
