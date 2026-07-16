import Foundation
import OpenFinderCore

actor ConfigurableProcessPluginRunner: PluginRunner {
    private let registry = ProcessRegistry()
    private var runtimePaths: PluginRuntimePaths

    init(runtimePaths: PluginRuntimePaths = .init()) {
        self.runtimePaths = runtimePaths
    }

    func update(python3Path: String?, nodePath: String?) {
        runtimePaths = .init(python3Path: python3Path, nodePath: nodePath)
    }

    func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        let runner = ProcessPluginRunner(registry: registry, runtimePaths: runtimePaths)
        return try await runner.run(request)
    }

    func cancel(taskID: UUID) async {
        await ProcessPluginRunner(registry: registry).cancel(taskID: taskID)
    }
}
