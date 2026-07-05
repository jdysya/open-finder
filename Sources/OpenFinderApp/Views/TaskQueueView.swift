import AppKit
import OpenFinderCore
import SwiftUI

struct TaskQueueView: View {
    let records: [TaskRecord]
    let logs: [UUID: [TaskLogLine]]
    let statusMessage: String
    let onCancel: (UUID) -> Void
    let onRetry: (UUID) -> Void
    let onCopyLogs: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Task Queue", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if records.isEmpty {
                ContentUnavailableView("No tasks yet", systemImage: "checkmark.circle", description: Text("Plugin, copy, move, upload, and download tasks will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(records) { record in
                    HStack {
                        statusIcon(record.status)
                        VStack(alignment: .leading) {
                            Text(record.title)
                                .font(.body)
                            Text(record.resultSummary ?? record.errorMessage ?? logs[record.id]?.last?.message ?? record.inputSummary)
                                .font(.caption)
                                .foregroundStyle(record.status == .failed ? .red : .secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let progress = record.progress, !record.status.isTerminal {
                            ProgressView(value: progress)
                                .frame(width: 120)
                        }
                        Text(record.status.rawValue)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Menu {
                            Button("Copy Logs") { onCopyLogs(record.id) }
                                .disabled((logs[record.id] ?? []).isEmpty)
                            if record.status == .queued || record.status == .running || record.status == .cancelling {
                                Button("Cancel", role: .destructive) { onCancel(record.id) }
                            }
                            if record.status == .failed || record.status == .cancelled {
                                Button("Retry") { onRetry(record.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 28)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(8)
        .background(.bar)
    }

    @ViewBuilder
    private func statusIcon(_ status: TaskStatus) -> some View {
        switch status {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running, .cancelling: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
        }
    }
}
