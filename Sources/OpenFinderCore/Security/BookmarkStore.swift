import Foundation

public enum BookmarkPermission: String, Codable, Sendable {
    case readOnly
    case readWrite
}

public struct BookmarkRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var originalPath: String
    public var bookmarkData: Data
    public var permission: BookmarkPermission
    public var createdAt: Date
    public var lastResolvedAt: Date?

    public init(id: UUID = UUID(), displayName: String, originalPath: String, bookmarkData: Data, permission: BookmarkPermission, createdAt: Date = Date(), lastResolvedAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.originalPath = originalPath
        self.bookmarkData = bookmarkData
        self.permission = permission
        self.createdAt = createdAt
        self.lastResolvedAt = lastResolvedAt
    }
}

public actor BookmarkStore {
    private var records: [UUID: BookmarkRecord] = [:]

    public init() {}

    public func save(_ record: BookmarkRecord) {
        records[record.id] = record
    }

    public func record(id: UUID) -> BookmarkRecord? { records[id] }

    public func all() -> [BookmarkRecord] { records.values.sorted { $0.createdAt < $1.createdAt } }

    public func remove(id: UUID) { records.removeValue(forKey: id) }
}
