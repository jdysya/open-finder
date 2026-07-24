import AppKit
import Foundation
import OpenFinderCore

extension AppModel {
    @discardableResult
    func refreshTasks() async -> Bool {
        let projection = await taskApplicationService.projection()
        publishTaskProjection(projection)
        return projection.hasActiveTasks
    }

    func cancelTask(_ id: UUID) {
        Task {
            let projection = await taskApplicationService.cancel(id)
            statusMessage = "Cancelled task \(id.uuidString.prefix(8))"
            publishTaskProjection(projection)
        }
    }

    func retryTask(_ id: UUID) {
        Task {
            do {
                let (retryID, projection) = try await taskApplicationService.retry(id)
                statusMessage = "Retried task \(retryID.uuidString.prefix(8))"
                publishTaskProjection(projection)
                await observeTask(retryID)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func copyLogs(for id: UUID) {
        let text = (taskLogs[id] ?? []).map { line in
            "[\(line.level)] \(line.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied logs for \(id.uuidString.prefix(8))"
    }

    func startTaskPolling() {
        taskApplicationService.startPolling { [weak self] projection in
            self?.publishTaskProjection(projection)
        }
    }

    func observeTask(_ id: UUID) async {
        do {
            let (record, projection) = try await taskApplicationService.waitForTerminalStatus(
                id,
                timeout: 86_400
            )
            if let clipboard = record.clipboardText {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clipboard, forType: .string)
            }
            publishTaskProjection(projection)
        } catch {
            statusMessage = error.localizedDescription
            await refreshTasks()
        }
    }

    private func publishTaskProjection(_ projection: TaskApplicationProjection) {
        if taskRecords != projection.records {
            taskRecords = projection.records
        }
        if taskLogs != projection.logs {
            taskLogs = projection.logs
        }
    }
}
