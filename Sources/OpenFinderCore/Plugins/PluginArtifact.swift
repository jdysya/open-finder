import Foundation

public struct PluginFileArtifact: Codable, Hashable, Sendable {
    public let artifactID: UUID
    public let relativePath: String
    public let mediaType: String
    public let byteCount: Int
    public let sha256: String

    public init(
        artifactID: UUID,
        relativePath: String,
        mediaType: String,
        byteCount: Int,
        sha256: String
    ) {
        self.artifactID = artifactID
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case artifactID, relativePath, mediaType, byteCount, sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        mediaType = try container.decode(String.self, forKey: .mediaType)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        sha256 = try container.decode(String.self, forKey: .sha256)
        artifactID = try container.decode(UUID.self, forKey: .artifactID)
    }
}

public struct PluginArtifact: Hashable, Sendable {
    public enum Payload: Hashable, Sendable {
        case inline(String)
        case file(PluginFileArtifact)
    }

    public let type: String
    public let payload: Payload

    public var content: String? {
        guard case .inline(let content) = payload else { return nil }
        return content
    }

    public var file: PluginFileArtifact? {
        guard case .file(let file) = payload else { return nil }
        return file
    }

    public init(type: String, content: String) {
        self.type = type
        self.payload = .inline(content)
    }

    public init(type: String, file: PluginFileArtifact) {
        self.type = type
        self.payload = .file(file)
    }
}

extension PluginArtifact: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, content, artifactID, relativePath, mediaType, byteCount, sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        let hasContent = container.contains(.content)
        let fileKeys: [CodingKeys] = [.relativePath, .mediaType, .byteCount, .sha256]
        let fileKeyCount = fileKeys.count { container.contains($0) }

        if hasContent, fileKeyCount == 0 {
            payload = .inline(try container.decode(String.self, forKey: .content))
        } else if !hasContent, fileKeyCount == fileKeys.count {
            let relativePath = try container.decode(String.self, forKey: .relativePath)
            let mediaType = try container.decode(String.self, forKey: .mediaType)
            let byteCount = try container.decode(Int.self, forKey: .byteCount)
            let sha256 = try container.decode(String.self, forKey: .sha256)
            payload = .file(.init(
                artifactID: try container.decode(UUID.self, forKey: .artifactID),
                relativePath: relativePath,
                mediaType: mediaType,
                byteCount: byteCount,
                sha256: sha256
            ))
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Artifact must contain exactly one complete inline or file payload."
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch payload {
        case .inline(let content):
            try container.encode(content, forKey: .content)
        case .file(let file):
            try container.encode(file.artifactID, forKey: .artifactID)
            try container.encode(file.relativePath, forKey: .relativePath)
            try container.encode(file.mediaType, forKey: .mediaType)
            try container.encode(file.byteCount, forKey: .byteCount)
            try container.encode(file.sha256, forKey: .sha256)
        }
    }
}
