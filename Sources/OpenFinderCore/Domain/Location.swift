import Foundation

public enum Location: Hashable, Codable, Sendable {
    case local(path: String)
    case webDAV(accountID: UUID, path: String)
    case rclone(remoteID: UUID, path: String)
    case remote(RemoteLocation)

    private enum CodingKeys: String, CodingKey { case type, path, accountID, remoteID, remote }
    private enum Kind: String, Codable { case local, webDAV, rclone, remote }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Kind.self, forKey: .type)
        switch type {
        case .local:
            self = .local(path: try container.decode(String.self, forKey: .path))
        case .webDAV:
            self = .webDAV(accountID: try container.decode(UUID.self, forKey: .accountID), path: try container.decode(String.self, forKey: .path))
        case .rclone:
            self = .rclone(remoteID: try container.decode(UUID.self, forKey: .remoteID), path: try container.decode(String.self, forKey: .path))
        case .remote:
            self = .remote(try container.decode(RemoteLocation.self, forKey: .remote))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let path):
            try container.encode(Kind.local, forKey: .type)
            try container.encode(path, forKey: .path)
        case .webDAV(let accountID, let path):
            try container.encode(Kind.webDAV, forKey: .type)
            try container.encode(accountID, forKey: .accountID)
            try container.encode(path, forKey: .path)
        case .rclone(let remoteID, let path):
            try container.encode(Kind.rclone, forKey: .type)
            try container.encode(remoteID, forKey: .remoteID)
            try container.encode(path, forKey: .path)
        case .remote(let remote):
            try container.encode(Kind.remote, forKey: .type)
            try container.encode(remote, forKey: .remote)
        }
    }

    public var displayPath: String {
        switch self {
        case .local(let path): path
        case .webDAV(_, let path): "webdav:\(path)"
        case .rclone(_, let path): "rclone:\(path)"
        case .remote(let remote): "\(remote.connectorID.rawValue):\(remote.path.displayPath)"
        }
    }

    public var localURL: URL? {
        if case .local(let path) = self { URL(fileURLWithPath: path) } else { nil }
    }
}
