import Foundation
import OpenFinderCore

enum PluginWorkspaceCleanupPolicy: Equatable {
    case preserve
    case removeTaskRootAfterSuccessfulPersistence
}

struct PluginWorkspace: Equatable {
    let taskRoot: URL
    let tempDirectory: URL
    let outputDirectory: URL
    let cleanupPolicy: PluginWorkspaceCleanupPolicy

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
            cleanupPolicy: .removeTaskRootAfterSuccessfulPersistence
        )
    }
}
