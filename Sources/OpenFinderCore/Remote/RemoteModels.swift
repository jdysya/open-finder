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
    public let tags: [FileTag]
    public let tagScopes: [FileTagScope]
    public let supportsTagEditing: Bool

    public init(
        id: String,
        name: String,
        path: RemotePath,
        kind: FileKind,
        size: Int64?,
        modificationDate: Date?,
        etag: String?,
        mimeType: String?,
        isReadable: Bool,
        isWritable: Bool,
        tags: [FileTag] = [],
        tagScopes: [FileTagScope] = [],
        supportsTagEditing: Bool = false
    ) {
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
        self.tags = tags
        self.tagScopes = tagScopes
        self.supportsTagEditing = supportsTagEditing
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case remotePath
        case kind
        case size
        case modificationDate
        case etag
        case mimeType
        case isReadable
        case isWritable
        case tags
        case tagScopes
        case supportsTagEditing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        remotePath = try container.decode(RemotePath.self, forKey: .remotePath)
        kind = try container.decode(FileKind.self, forKey: .kind)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        modificationDate = try container.decodeIfPresent(Date.self, forKey: .modificationDate)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        isReadable = try container.decode(Bool.self, forKey: .isReadable)
        isWritable = try container.decode(Bool.self, forKey: .isWritable)
        tags = try container.decodeIfPresent([FileTag].self, forKey: .tags) ?? []
        tagScopes = try container.decodeIfPresent([FileTagScope].self, forKey: .tagScopes) ?? []
        supportsTagEditing = try container.decodeIfPresent(Bool.self, forKey: .supportsTagEditing) ?? false
    }
}

public struct RemoteDirectoryCapabilities: Codable, Hashable, Sendable {
    public let isReadable: Bool
    public let isWritable: Bool
    public let supportsTags: Bool

    public init(isReadable: Bool, isWritable: Bool, supportsTags: Bool = false) {
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.supportsTags = supportsTags
    }

    private enum CodingKeys: String, CodingKey {
        case isReadable
        case isWritable
        case supportsTags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isReadable: try container.decode(Bool.self, forKey: .isReadable),
            isWritable: try container.decode(Bool.self, forKey: .isWritable),
            supportsTags: try container.decodeIfPresent(Bool.self, forKey: .supportsTags) ?? false
        )
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
