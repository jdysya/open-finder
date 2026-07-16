import Foundation
import OpenFinderCore
@testable import OpenFinderApp

struct StubPluginConnectionChecker: PluginConnectionChecking {
    let status: PluginConnectionStatus

    func check(
        manifest: PluginManifest,
        values: [String: String],
        secretReferences: [String: String]
    ) async -> PluginConnectionStatus { status }

    static let ready = StubPluginConnectionChecker(status: .init(
        state: .ready,
        guidance: "Ready",
        protocolVersion: 1,
        pluginID: "fixture.http",
        pluginVersion: "1.0.0"
    ))
}

actor RecordingPluginRunner: PluginRunner {
    private var requests: [PluginRunRequest] = []
    private let progress: PluginProgress?

    init(progress: PluginProgress? = nil) {
        self.progress = progress
    }

    func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        requests.append(request)
        if let progress { request.onEvent?(.progress(progress)) }
        return .init(
            exitCode: 0,
            events: [.result(status: "success", message: "done", clipboard: nil, artifacts: [])],
            stdout: "",
            stderr: ""
        )
    }

    func cancel(taskID: UUID) async {}
    func captured() -> [PluginRunRequest] { requests }
}

actor BlockingPluginRunner: PluginRunner {
    private var startedIDs: [UUID] = []
    private var cancelledIDs: [UUID] = []

    func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        startedIDs.append(request.input.taskID)
        do {
            while true { try await Task.sleep(for: .seconds(1)) }
        } catch is CancellationError {
            cancelledIDs.append(request.input.taskID)
            throw CancellationError()
        }
    }

    func cancel(taskID: UUID) async {
        cancelledIDs.append(taskID)
    }

    func started() -> [UUID] { startedIDs }
    func cancelled() -> [UUID] { cancelledIDs }
}

actor FailingPluginRunner: PluginRunner {
    private var requests: [PluginRunRequest] = []

    func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        requests.append(request)
        throw OpenFinderError.operationFailed("fixture failure")
    }

    func cancel(taskID: UUID) async {}
    func captured() -> [PluginRunRequest] { requests }
}

actor RuntimeCancellingPluginRunner: PluginRunner {
    private var requests: [PluginRunRequest] = []

    func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        requests.append(request)
        throw CancellationError()
    }

    func cancel(taskID: UUID) async {}
    func captured() -> [PluginRunRequest] { requests }
}

enum AppPluginFixture {
    static func manifest(id: String, execution: PluginExecution) -> PluginManifest {
        .init(
            schemaVersion: execution.isHTTP ? 2 : 1,
            id: id,
            name: id,
            version: "1.0.0",
            description: nil,
            author: nil,
            execution: execution,
            actions: [action],
            permissions: .init(
                readFiles: "selected",
                writeFiles: "taskOutput",
                network: .init(required: execution.isHTTP, hosts: ["127.0.0.1"]),
                clipboardWrite: false,
                clipboardRead: false,
                keychainSecrets: execution.isHTTP ? ["serverToken"] : [],
                remoteAccounts: false,
                runExternalCommands: !execution.isHTTP
            ),
            configuration: execution.isHTTP
                ? [.init(key: "serverURL", type: "string", title: "Server", required: true)]
                : []
        )
    }

    static let action = PluginActionManifest(
        id: "run",
        title: "Run",
        category: nil,
        selection: .init(minItems: 1, maxItems: 1, allowDirectories: false),
        match: nil,
        output: nil
    )

    @MainActor
    static func app(
        root: URL,
        process: any PluginRunner,
        http: any PluginRunner,
        checker: any PluginConnectionChecking = StubPluginConnectionChecker.ready,
        keychain: any KeychainStore = InMemoryKeychainStore(),
        workspaceMaintenance: PluginWorkspaceMaintenance = .live()
    ) -> AppModel {
        AppModel(
            remoteDirectory: RemoteAccountDirectory(storageURL: root.appendingPathComponent("accounts.json")),
            configurationStore: JSONConfigStore(url: root.appendingPathComponent("config.json")),
            keychainStore: keychain,
            videoAnalysisStore: VideoAnalysisResultStore(directory: root.appendingPathComponent("analysis")),
            pluginRunnerRouter: PluginRunnerRouter(processRunner: process, httpRunner: http),
            pluginConnectionChecker: checker,
            pluginWorkspaceMaintenance: workspaceMaintenance,
            startAutomatically: false
        )
    }

    @MainActor
    static func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0 ..< 200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OpenFinderError.timeout("App plugin test timed out")
    }
}

private extension PluginExecution {
    var isHTTP: Bool {
        if case .http = self { true } else { false }
    }
}
