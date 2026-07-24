import Foundation

public struct ArtifactRecord: Codable, Hashable, Sendable {
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    public let id: UUID
    public let schemaID: String
    public let relativePath: String
    public let mediaType: String
    public let byteCount: Int
    public let sha256: String
    public let state: ArtifactLifecycleState
    public let stagedAt: Date
    public let finishedAt: Date?

    public init(
        id: UUID,
        schemaID: String,
        relativePath: String,
        mediaType: String,
        byteCount: Int,
        sha256: String,
        state: ArtifactLifecycleState,
        stagedAt: Date,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.schemaID = schemaID
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.state = state
        self.stagedAt = stagedAt
        self.finishedAt = finishedAt
    }

    public var retentionDeadline: Date? {
        guard state == .committed else { return nil }
        return finishedAt?.addingTimeInterval(Self.retentionInterval)
    }

    public var reconciliationState: ArtifactReconciliationState {
        switch state {
        case .staging: .validate
        case .validated: .publishFile
        case .filePublished: .linkRow
        case .rowLinked: .commit
        case .committed: .stable
        case .cleaned: .cleanupComplete
        }
    }

    public func validate() throws {
        guard relativePath.isConfinedRelativePath else {
            throw ArtifactLifecycleError.unconfinedRelativePath(relativePath)
        }
        guard byteCount >= 0 else {
            throw ArtifactLifecycleError.invalidByteCount(byteCount)
        }
        if (state == .committed || state == .cleaned), finishedAt == nil {
            throw ArtifactLifecycleError.missingFinishedAt
        }
    }

    public func transition(to next: ArtifactLifecycleState, at date: Date = .now) throws -> Self {
        guard next != state else { return self }
        let expectedNext: ArtifactLifecycleState? = switch state {
        case .staging: .validated
        case .validated: .filePublished
        case .filePublished: .rowLinked
        case .rowLinked: .committed
        case .committed: .cleaned
        case .cleaned: nil
        }
        let isCancellationCleanup = state.isPreCommit && next == .cleaned
        guard expectedNext == next || isCancellationCleanup else {
            throw ArtifactLifecycleError.invalidTransition(from: state, to: next)
        }
        return Self(
            id: id,
            schemaID: schemaID,
            relativePath: relativePath,
            mediaType: mediaType,
            byteCount: byteCount,
            sha256: sha256,
            state: next,
            stagedAt: stagedAt,
            finishedAt: next == .committed || (next == .cleaned && finishedAt == nil) ? date : finishedAt
        )
    }

    public func cancelling(at date: Date = .now) throws -> Self {
        state == .committed || state == .cleaned ? self : try transition(to: .cleaned, at: date)
    }

    public func cleaningExpired(at date: Date = .now) throws -> Self {
        guard state == .committed, let retentionDeadline, date >= retentionDeadline else {
            throw ArtifactLifecycleError.retentionNotExpired
        }
        return try transition(to: .cleaned, at: date)
    }
}

public enum ArtifactLifecycleState: String, Codable, Hashable, Sendable {
    case staging
    case validated
    case filePublished
    case rowLinked
    case committed
    case cleaned

    fileprivate var isPreCommit: Bool {
        switch self {
        case .staging, .validated, .filePublished, .rowLinked: true
        case .committed, .cleaned: false
        }
    }
}

public enum ArtifactReconciliationState: String, Codable, Hashable, Sendable {
    case validate
    case publishFile
    case linkRow
    case commit
    case stable
    case cleanupComplete
}

public enum ArtifactLifecycleError: Error, Equatable, Sendable {
    case invalidTransition(from: ArtifactLifecycleState, to: ArtifactLifecycleState)
    case unconfinedRelativePath(String)
    case invalidByteCount(Int)
    case missingFinishedAt
    case retentionNotExpired
}

extension String {
    fileprivate var isConfinedRelativePath: Bool {
        guard !isEmpty, !NSString(string: self).isAbsolutePath else { return false }
        return !NSString(string: self).pathComponents.contains { $0 == "." || $0 == ".." }
    }
}
