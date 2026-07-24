import Foundation

public struct ArtifactMetadataEntry: Sendable, Hashable {
    public let taskID: UUID
    public let record: ArtifactRecord

    public init(taskID: UUID, record: ArtifactRecord) {
        self.taskID = taskID
        self.record = record
    }
}

public protocol ArtifactMetadataBackend: Sendable {
    func upsert(_ record: ArtifactRecord, taskID: UUID) async throws
    func record(id: UUID) async -> ArtifactRecord?
    func entries() async -> [ArtifactMetadataEntry]
    func remove(id: UUID) async
    func link(_ artifactID: UUID, to taskID: UUID) async throws
    func isLinked(_ artifactID: UUID, to taskID: UUID) async -> Bool
    func markTaskEffectsCommitted(_ taskID: UUID) async throws
    func taskEffectsCommitted(_ taskID: UUID) async -> Bool
    func recordCleanupFailure(taskID: UUID, message: String) async
    func cleanupFailure(taskID: UUID) async -> String?
    func clearCleanupFailure(taskID: UUID) async
}

public actor InMemoryArtifactMetadataBackend: ArtifactMetadataBackend {
    private var storedEntries: [UUID: ArtifactMetadataEntry] = [:]
    private var links: [UUID: Set<UUID>] = [:]
    private var committedTasks: Set<UUID> = []
    private var cleanupFailures: [UUID: String] = [:]

    public init() {}

    public func upsert(_ record: ArtifactRecord, taskID: UUID) throws {
        try record.validate()
        storedEntries[record.id] = .init(taskID: taskID, record: record)
    }

    public func record(id: UUID) -> ArtifactRecord? {
        storedEntries[id]?.record
    }

    public func records() -> [ArtifactRecord] {
        storedEntries.values.map(\.record).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func entries() -> [ArtifactMetadataEntry] {
        storedEntries.values.sorted { $0.record.id.uuidString < $1.record.id.uuidString }
    }

    public func remove(id: UUID) {
        storedEntries.removeValue(forKey: id)
        for taskID in links.keys {
            links[taskID]?.remove(id)
        }
    }

    public func link(_ artifactID: UUID, to taskID: UUID) throws {
        guard storedEntries[artifactID]?.taskID == taskID else {
            throw ArtifactStoreError.metadataRecordMissing(artifactID)
        }
        links[taskID, default: []].insert(artifactID)
    }

    public func isLinked(_ artifactID: UUID, to taskID: UUID) -> Bool {
        links[taskID]?.contains(artifactID) == true
    }

    public func markTaskEffectsCommitted(_ taskID: UUID) {
        committedTasks.insert(taskID)
    }

    public func taskEffectsCommitted(_ taskID: UUID) -> Bool {
        committedTasks.contains(taskID)
    }

    public func recordCleanupFailure(taskID: UUID, message: String) {
        cleanupFailures[taskID] = message
    }

    public func cleanupFailure(taskID: UUID) -> String? {
        cleanupFailures[taskID]
    }

    public func clearCleanupFailure(taskID: UUID) {
        cleanupFailures.removeValue(forKey: taskID)
    }
}
