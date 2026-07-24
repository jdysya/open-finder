import AppKit
import Foundation
import OpenFinderCore

extension AppModel {
    @discardableResult
    func refreshTasks() async -> Bool {
        let projection = await services.taskProjection()
        publishTaskProjection(projection)
        return projection.hasActiveTasks
    }

    func cancelTask(_ id: UUID) {
        Task {
            let projection = await services.cancelTask(id)
            statusMessage = "Cancelled task \(id.uuidString.prefix(8))"
            publishTaskProjection(projection)
        }
    }

    func retryTask(_ id: UUID) {
        Task {
            do {
                let (retryID, projection) = try await services.retryTask(id)
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
        services.startTaskObservation { [weak self] projection in
            self?.publishTaskProjection(projection)
        }
    }

    func observeTask(_ id: UUID) async {
        do {
            let (record, projection) = try await services.awaitTask(
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
