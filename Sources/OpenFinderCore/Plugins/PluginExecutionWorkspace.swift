import Foundation

public enum PluginExecutionWorkspaceCleanupPolicy: Hashable, Sendable {
    case preserve
    case removeTaskRootAfterExecution
}

public struct PluginExecutionWorkspace: Hashable, Sendable {
    public let taskRoot: URL
    public let tempDirectory: URL
    public let outputDirectory: URL
    public let cleanupPolicy: PluginExecutionWorkspaceCleanupPolicy

    public init(
        taskRoot: URL,
        tempDirectory: URL,
        outputDirectory: URL,
        cleanupPolicy: PluginExecutionWorkspaceCleanupPolicy
    ) {
        self.taskRoot = taskRoot
        self.tempDirectory = tempDirectory
        self.outputDirectory = outputDirectory
        self.cleanupPolicy = cleanupPolicy
    }

    public static func make(
        execution: PluginExecution,
        taskID: UUID,
        currentLocation: Location,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Self {
        switch execution {
        case .process:
            let root = temporaryDirectory
                .appendingPathComponent("OpenFinderTasks", isDirectory: true)
                .appendingPathComponent(taskID.uuidString, isDirectory: true)
            return .init(
                taskRoot: root,
                tempDirectory: root,
                outputDirectory: currentLocation.localURL ?? root.appendingPathComponent(
                    "output",
                    isDirectory: true
                ),
                cleanupPolicy: .preserve
            )
        case .http:
            let root = temporaryDirectory
                .appendingPathComponent("OpenFinderHTTPTasks", isDirectory: true)
                .appendingPathComponent(taskID.uuidString, isDirectory: true)
            return .init(
                taskRoot: root,
                tempDirectory: root.appendingPathComponent("temp", isDirectory: true),
                outputDirectory: root.appendingPathComponent("output", isDirectory: true),
                cleanupPolicy: .removeTaskRootAfterExecution
            )
        }
    }

    public func createDirectories() throws {
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
    }

    public func cleanup() throws {
        guard cleanupPolicy == .removeTaskRootAfterExecution,
              FileManager.default.fileExists(atPath: taskRoot.path) else {
            return
        }
        try FileManager.default.removeItem(at: taskRoot)
    }
}

public struct PluginExecutionWorkspaceMaintenance: Sendable {
    private let operation: @Sendable (PluginExecutionWorkspace) throws -> Void

    public init(_ operation: @escaping @Sendable (PluginExecutionWorkspace) throws -> Void) {
        self.operation = operation
    }

    public func cleanup(_ workspace: PluginExecutionWorkspace) throws {
        try operation(workspace)
    }

    public static let live = PluginExecutionWorkspaceMaintenance { workspace in
        try workspace.cleanup()
    }
}
