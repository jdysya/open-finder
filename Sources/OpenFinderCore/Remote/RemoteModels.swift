import Foundation

public enum RemoteProviderKind: String, Codable, Hashable, Sendable {
    case webDAV
    case kodbox
    case sftp
    case s3
    case rclone
}

public struct RemotePath: Codable, Hashable, Sendable {
    public let identifier: String
    public let displayPath: String

    public init(identifier: String, displayPath: String) {
        self.identifier = identifier
        self.displayPath = displayPath
    }
}

public struct RemoteLocation: Codable, Hashable, Sendable {
    public let accountID: UUID
    public let connectorID: RemoteConnectorID
    public let path: RemotePath

    public init(accountID: UUID, connectorID: RemoteConnectorID, path: RemotePath) {
        self.accountID = accountID
        self.connectorID = connectorID
        self.path = path
    }
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
    public let remotePath: RemotePath
    public let kind: FileKind
    public let size: Int64?
    public let modificationDate: Date?
    public let etag: String?
    public let mimeType: String?
    public let isReadable: Bool
    public let isWritable: Bool

    public init(id: String, name: String, path: RemotePath, kind: FileKind, size: Int64?, modificationDate: Date?, etag: String?, mimeType: String?, isReadable: Bool, isWritable: Bool) {
        self.id = id
        self.name = name
        self.path = path.displayPath
        self.remotePath = path
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.etag = etag
        self.mimeType = mimeType
        self.isReadable = isReadable
        self.isWritable = isWritable
    }
}

public struct RemoteDirectoryCapabilities: Codable, Hashable, Sendable {
    public let isReadable: Bool
    public let isWritable: Bool

    public init(isReadable: Bool, isWritable: Bool) {
        self.isReadable = isReadable
        self.isWritable = isWritable
    }
}

public struct RemoteDirectoryListing: Codable, Hashable, Sendable {
    public let current: RemotePath
    public let parent: RemotePath?
    public let items: [RemoteItem]
    public let capabilities: RemoteDirectoryCapabilities

    public init(current: RemotePath, parent: RemotePath?, items: [RemoteItem], capabilities: RemoteDirectoryCapabilities) {
        self.current = current
        self.parent = parent
        self.items = items
        self.capabilities = capabilities
    }
}

public protocol RemoteProvider: Actor {
    func list(directory: RemotePath) async throws -> RemoteDirectoryListing
    func createDirectory(in parent: RemotePath, named name: String) async throws
    func delete(item: RemotePath) async throws
    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws
    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws
    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID
    func download(item: RemotePath, to localURL: URL) async throws -> TaskID
}
