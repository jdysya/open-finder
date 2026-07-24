import Foundation
import OpenFinderCore
import SwiftUI

enum PaneID: String {
    case left
    case right
}

@MainActor
final class AppModel: ObservableObject {
    @Published var leftPane: BrowserPaneModel
    @Published var rightPane: BrowserPaneModel
    @Published var activePane: PaneID = .left
    @Published var taskRecords: [TaskRecord] = []
    @Published var taskLogs: [UUID: [TaskLogLine]] = [:]
    @Published var loadedPlugins: [LoadedPlugin] = []
    @Published var pluginLoadDiagnostics: [PluginLoadDiagnostic] = []
    @Published var remoteAccounts: [RemoteAccount] = []
    @Published var statusMessage = "Ready"
    @Published var pendingTransferOverwrite: PendingTransferOverwrite?
    @Published var presentedPluginResult: PluginResultProjection?
    @Published var pluginConnectionStatuses: [String: PluginConnectionStatus] = [:]
    @Published var durableHandlerReadiness: AppDurableHandlerReadiness = .checking
    @Published var configuration = AppConfiguration() {
        didSet { services.publish(configuration: configuration) }
    }

    let services: ApplicationServices
    var durableReadinessTask: Task<Result<Void, any Error>, Never>?
    var didLoadInitialState = false

    init(
        services: ApplicationServices = ApplicationServices(),
        startAutomatically: Bool = true
    ) {
        self.services = services
        let panes = services.makeBrowserPanes()
        leftPane = panes.left
        rightPane = panes.right
        let readinessTask: Task<Result<Void, any Error>, Never> = Task { [weak self] in
            guard let self else {
                return .failure(CancellationError())
            }
            do {
                try await services.prepareDurableExecution()
                await refreshTasks()
                if startAutomatically {
                    await loadInitialState()
                }
                await services.resumeRecoveredWork()
                durableHandlerReadiness = .ready
                if startAutomatically {
                    startTaskPolling()
                }
                return .success(())
            } catch {
                durableHandlerReadiness = .unavailable(error.localizedDescription)
                if startAutomatically {
                    await loadInitialState()
                    startTaskPolling()
                }
                return .failure(error)
            }
        }
        durableReadinessTask = readinessTask
        services.attachReadiness(readinessTask)
    }

    var activeBrowser: BrowserPaneModel {
        activePane == .left ? leftPane : rightPane
    }

    var inactiveBrowser: BrowserPaneModel {
        activePane == .left ? rightPane : leftPane
    }

    func browser(for id: PaneID) -> BrowserPaneModel {
        id == .left ? leftPane : rightPane
    }
}

struct PendingDeletion: Identifiable {
    let id = UUID()
    let items: [FileItem]
}

struct PendingTransferOverwrite: Identifiable {
    let id = UUID()
    let items: [FileItem]
    let source: Location
    let destination: Location
    let move: Bool
    let conflicts: [TransferConflict]
    let sourcePaneID: PaneID
    let destinationPaneID: PaneID

    var message: String {
        let names = conflicts.prefix(5).map(\.itemName).joined(separator: ", ")
        let remaining = conflicts.count > 5 ? " 等另外 \(conflicts.count - 5) 项" : ""
        let action = move ? "移动" : "复制"
        return "\(action)目标位置已存在 \(conflicts.count) 个同名项目：\(names)\(remaining)。是否覆盖现有项目？"
    }
}
