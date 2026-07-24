import OpenFinderCore
@testable import OpenFinderApp

@MainActor
extension AppModel {
    var taskQueue: TaskQueueService {
        services.taskService.queue
    }

    var taskApplicationService: TaskApplicationService {
        services.taskService
    }

    var fileBrowserService: FileBrowserService {
        services.browserService
    }
}
