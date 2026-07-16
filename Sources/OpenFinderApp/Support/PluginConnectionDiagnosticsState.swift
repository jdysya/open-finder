import OpenFinderCore

struct PluginConnectionDiagnosticsState: Equatable {
    let status: PluginConnectionStatus?

    var isTestButtonEnabled: Bool { status?.state != .connecting }
    var isSubmissionEnabled: Bool { status?.canSubmit == true }

    var title: String {
        switch status?.state {
        case .connecting: "Connecting"
        case .ready: "Ready"
        case .degraded: "Degraded"
        case .unavailable: "Unavailable"
        case nil: "Not Tested"
        }
    }

    var systemImage: String {
        switch status?.state {
        case .connecting: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .unavailable: "xmark.octagon.fill"
        case nil: "questionmark.circle"
        }
    }
}
