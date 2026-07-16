import AppKit
import Foundation
import OpenFinderCore

extension AppModel {
    @discardableResult
    func refreshTasks() async -> Bool {
        let records = await taskQueue.history().sorted { $0.createdAt > $1.createdAt }
        var logs: [UUID: [TaskLogLine]] = [:]
        for record in records {
            logs[record.id] = await taskQueue.logs(for: record.id)
        }
        if taskRecords != records {
            taskRecords = records
        }
        if taskLogs != logs {
            taskLogs = logs
        }
        return records.contains { !$0.status.isTerminal }
    }

    func cancelTask(_ id: UUID) {
        Task {
            await taskQueue.cancel(id)
            statusMessage = "Cancelled task \(id.uuidString.prefix(8))"
            await refreshTasks()
        }
    }

    func retryTask(_ id: UUID) {
        Task {
            do {
                let retryID = try await taskQueue.retry(id)
                statusMessage = "Retried task \(retryID.uuidString.prefix(8))"
                await refreshTasks()
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
        taskPollingTask?.cancel()
        taskPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let hasActiveTasks = await self?.refreshTasks() ?? false
                let interval: UInt64 = hasActiveTasks ? 250_000_000 : 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func observeTask(_ id: UUID) async {
        do {
            let record = try await taskQueue.waitForTerminalStatus(id, timeout: 86_400)
            if let clipboard = record.clipboardText {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clipboard, forType: .string)
            }
            await refreshTasks()
        } catch {
            statusMessage = error.localizedDescription
            await refreshTasks()
        }
    }
}
