import Foundation

public actor PluginRunnerRouter: PluginRunner {
    private enum Transport { case process, http }

    private let processRunner: any PluginRunner
    private let httpRunner: any PluginRunner
    private var active: [UUID: Transport] = [:]

    public init(processRunner: any PluginRunner = ProcessPluginRunner(), httpRunner: any PluginRunner) {
        self.processRunner = processRunner
        self.httpRunner = httpRunner
    }

    public func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        let transport: Transport
        let runner: any PluginRunner
        switch request.manifest.execution {
        case .process:
            transport = .process
            runner = processRunner
        case .http:
            transport = .http
            runner = httpRunner
        }
        active[request.input.taskID] = transport
        defer { active.removeValue(forKey: request.input.taskID) }
        return try await runner.run(request)
    }

    public func cancel(taskID: UUID) async {
        switch active[taskID] {
        case .process: await processRunner.cancel(taskID: taskID)
        case .http: await httpRunner.cancel(taskID: taskID)
        case nil: return
        }
    }
}
