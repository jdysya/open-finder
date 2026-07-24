import Foundation

public enum FileCapabilityDecision: Codable, Hashable, Sendable {
    case allowed
    case rejected(FileCapabilityUnsupportedReason)

    public init(_ support: FileCapabilitySupport) {
        switch support {
        case .supported:
            self = .allowed
        case .unsupported(let reason):
            self = .rejected(reason)
        }
    }
}

public enum FileLocationCapabilityAdapter {
    public static func apply(
        _ decision: FileCapabilityDecision,
        to location: FileLocation
    ) -> FileLocationResolution {
        switch decision {
        case .allowed:
            .resolved(location)
        case .rejected(let reason):
            .unsupported(reason)
        }
    }
}

public enum FileOperationPreflight: Codable, Hashable, Sendable {
    case proceed
    case rejected(FileCapabilityUnsupportedReason)

    public static func evaluate(_ decision: FileCapabilityDecision) -> Self {
        switch decision {
        case .allowed:
            .proceed
        case .rejected(let reason):
            .rejected(reason)
        }
    }
}

public enum FileCapabilityPresentationState: Codable, Hashable, Sendable {
    case enabled
    case disabled(FileCapabilityUnsupportedReason)

    public init(_ decision: FileCapabilityDecision) {
        switch decision {
        case .allowed:
            self = .enabled
        case .rejected(let reason):
            self = .disabled(reason)
        }
    }
}
