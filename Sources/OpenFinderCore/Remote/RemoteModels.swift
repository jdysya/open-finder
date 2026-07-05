import Foundation

public enum RemoteProviderKind: String, Codable, Hashable, Sendable {
    case webDAV
    case sftp
    case s3
    case rclone
}

public struct RemoteAccount: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var provider: RemoteProviderKind
    public var baseURL: URL?
    public var username: String?
    public var secretKeychainRef: String?
    public var options: [String: String]

    public init(id: UUID = UUID(), name: String, provider: RemoteProviderKind, baseURL: URL?, username: String?, secretKeychainRef: String?, options: [String: String]) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.username = username
        self.secretKeychainRef = secretKeychainRef
        self.options = options
    }
}

public struct RemoteItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let kind: FileKind
    public let size: Int64?
    public let modificationDate: Date?
    public let etag: String?
    public let mimeType: String?

    public init(id: String, name: String, path: String, kind: FileKind, size: Int64?, modificationDate: Date?, etag: String?, mimeType: String?) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.etag = etag
        self.mimeType = mimeType
    }
}

public protocol RemoteProvider {
    func list(path: String) async throws -> [RemoteItem]
    func mkdir(path: String) async throws
    func delete(path: String) async throws
    func move(from: String, to: String) async throws
    func copy(from: String, to: String) async throws
    func upload(localURL: URL, remotePath: String) async throws -> TaskID
    func download(remotePath: String, localURL: URL) async throws -> TaskID
}
