import Foundation
import OpenFinderCore

enum PluginWorkspaceCleanupPolicy: Equatable {
    case preserve
    case removeTaskRootAfterExecution
}

struct PluginWorkspace: Equatable {
    let taskRoot: URL
    let tempDirectory: URL
    let outputDirectory: URL
    let cleanupPolicy: PluginWorkspaceCleanupPolicy

    init(
        taskRoot: URL,
        tempDirectory: URL,
        outputDirectory: URL,
        cleanupPolicy: PluginWorkspaceCleanupPolicy
    ) {
        self.taskRoot = taskRoot
        self.tempDirectory = tempDirectory
        self.outputDirectory = outputDirectory
        self.cleanupPolicy = cleanupPolicy
    }

    static func make(taskID: UUID, currentLocation: Location) -> PluginWorkspace {
        let taskRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderTasks", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
        let outputDirectory: URL
        if let localURL = currentLocation.localURL {
            outputDirectory = localURL
        } else {
            outputDirectory = taskRoot.appendingPathComponent("output", isDirectory: true)
        }
        return .init(
            taskRoot: taskRoot,
            tempDirectory: taskRoot,
            outputDirectory: outputDirectory,
            cleanupPolicy: .preserve
        )
    }

    static func makeHTTP(taskID: UUID) -> PluginWorkspace {
        let taskRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderHTTPTasks", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
        return .init(
            taskRoot: taskRoot,
            tempDirectory: taskRoot.appendingPathComponent("temp", isDirectory: true),
            outputDirectory: taskRoot.appendingPathComponent("output", isDirectory: true),
            cleanupPolicy: .removeTaskRootAfterExecution
        )
    }

    func removeTaskRootIfNeeded() throws {
        guard cleanupPolicy == .removeTaskRootAfterExecution,
              FileManager.default.fileExists(atPath: taskRoot.path) else { return }
        try FileManager.default.removeItem(at: taskRoot)
    }

    init(executionWorkspace: PluginExecutionWorkspace) {
        let policy: PluginWorkspaceCleanupPolicy
        switch executionWorkspace.cleanupPolicy {
        case .preserve:
            policy = .preserve
        case .removeTaskRootAfterExecution:
            policy = .removeTaskRootAfterExecution
        }
        self.init(
            taskRoot: executionWorkspace.taskRoot,
            tempDirectory: executionWorkspace.tempDirectory,
            outputDirectory: executionWorkspace.outputDirectory,
            cleanupPolicy: policy
        )
    }
}

struct PluginWorkspaceMaintenance: Sendable {
    static let cleanupWarning = "HTTP plugin workspace cleanup failed; stale temporary data may remain."

    let cleanup: @Sendable (PluginWorkspace) throws -> Void
    let reportFailure: @Sendable (TaskExecutionContext) async -> Void

    static func live(
        cleanup: @escaping @Sendable (PluginWorkspace) throws -> Void = { workspace in
            try workspace.removeTaskRootIfNeeded()
        }
    ) -> PluginWorkspaceMaintenance {
        .init(
            cleanup: cleanup,
            reportFailure: { context in
                await context.appendLog(cleanupWarning, level: "warning")
            }
        )
    }
}
