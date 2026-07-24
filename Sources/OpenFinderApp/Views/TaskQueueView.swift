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

    @State private var expandedTaskIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Task Queue", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if records.isEmpty {
                VStack(spacing: 4) {
                    Label("No tasks yet", systemImage: "checkmark.circle")
                        .font(.headline)
                    Text("Plugin, copy, move, upload, and download tasks will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("task-queue-empty-state")
            } else {
                List(records) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        taskHeader(record)
                        if expandedTaskIDs.contains(record.id) {
                            logLines(for: record)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .padding(8)
        .background(.bar)
    }

    private func taskHeader(_ record: TaskRecord) -> some View {
        HStack(alignment: .center, spacing: 8) {
            statusIcon(record.status)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.body)
                    .lineLimit(1)
                Text(taskDetail(record))
                    .font(.caption)
                    .foregroundStyle(record.status == .failed ? .red : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let progress = record.progress, !record.status.isTerminal {
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 8) {
                        if let units = progressUnits(record.progressDetail) {
                            Text(units)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                    }
                    ProgressView(value: progress)
                        .frame(width: 150)
                }
            }
            Text(taskStatusLabel(record))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            if !(logs[record.id] ?? []).isEmpty {
                Button {
                    toggleLogs(for: record.id)
                } label: {
                    Image(systemName: expandedTaskIDs.contains(record.id) ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .help(expandedTaskIDs.contains(record.id) ? "Hide recent logs" : "Show recent logs")
            }
            taskMenu(record)
        }
    }

    private func logLines(for record: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            ForEach(Array((logs[record.id] ?? []).suffix(8))) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.date, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(line.message)
                        .font(.caption.monospaced())
                        .foregroundStyle(line.level == "error" ? .red : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
        .padding(.leading, 26)
    }

    private func taskDetail(_ record: TaskRecord) -> String {
        if let interventionMessage = record.reasonCode?.interventionMessage {
            return interventionMessage
        }
        if record.status.isTerminal {
            return record.resultSummary ?? record.errorMessage ?? record.inputSummary
        }
        let phase = record.progressDetail?.phase
        let detail = record.progressDetail?.detail
        switch (phase, detail) {
        case let (.some(phase), .some(detail)) where phase != detail:
            return "\(phase) — \(detail)"
        case let (.some(phase), _):
            return phase
        case let (_, .some(detail)):
            return detail
        default:
            return logs[record.id]?.last?.message ?? record.inputSummary
        }
    }

    private func taskStatusLabel(_ record: TaskRecord) -> String {
        record.reasonCode?.interventionMessage == nil
            ? record.status.rawValue
            : "needs attention"
    }

    private func progressUnits(_ progress: TaskProgressSnapshot?) -> String? {
        guard let completed = progress?.completed, let total = progress?.total else { return nil }
        let suffix = progress?.unit.map { " \($0)" } ?? ""
        return "\(completed)/\(total)\(suffix)"
    }

    private func toggleLogs(for id: UUID) {
        if expandedTaskIDs.contains(id) {
            expandedTaskIDs.remove(id)
        } else {
            expandedTaskIDs.insert(id)
        }
    }

    private func taskMenu(_ record: TaskRecord) -> some View {
        Menu {
            Button("Copy Logs") { onCopyLogs(record.id) }
                .disabled((logs[record.id] ?? []).isEmpty)
            if record.status == .queued || record.status == .running || record.status == .cancelling {
                Button("Cancel", role: .destructive) { onCancel(record.id) }
            }
            if record.status == .failed || record.status == .cancelled || record.status == .interrupted {
                Button("Retry") { onRetry(record.id) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
    }

    @ViewBuilder
    private func statusIcon(_ status: TaskStatus) -> some View {
        switch status {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running, .cancelling: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
        case .interrupted: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .unavailable: Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
        }
    }
}
