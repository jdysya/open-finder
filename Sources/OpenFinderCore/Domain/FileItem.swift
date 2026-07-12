import Foundation

public enum FileKind: String, Codable, Hashable, Sendable, CaseIterable {
    case file
    case directory
    case symlink
    case package
    case unknown
}

public struct FileItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let location: Location
    public let kind: FileKind
    public let size: Int64?
    public let modificationDate: Date?
    public let creationDate: Date?
    public let uti: String?
    public let mimeType: String?
    public let fileExtension: String?
    public let isHidden: Bool
    public let isReadable: Bool
    public let isWritable: Bool
    public let tags: [FileTag]
    public let tagScopes: [FileTagScope]
    public let supportsTagEditing: Bool

    public init(
        id: String,
        name: String,
        location: Location,
        kind: FileKind,
        size: Int64?,
        modificationDate: Date?,
        creationDate: Date?,
        uti: String?,
        mimeType: String?,
        fileExtension: String?,
        isHidden: Bool,
        isReadable: Bool,
        isWritable: Bool,
        tags: [FileTag] = [],
        tagScopes: [FileTagScope] = [],
        supportsTagEditing: Bool = false
    ) {
        self.id = id
        self.name = name
        self.location = location
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.uti = uti
        self.mimeType = mimeType
        self.fileExtension = fileExtension
        self.isHidden = isHidden
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.tags = tags
        self.tagScopes = tagScopes
        self.supportsTagEditing = supportsTagEditing
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case location
        case kind
        case size
        case modificationDate
        case creationDate
        case uti
        case mimeType
        case fileExtension
        case isHidden
        case isReadable
        case isWritable
        case tags
        case tagScopes
        case supportsTagEditing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            location: try container.decode(Location.self, forKey: .location),
            kind: try container.decode(FileKind.self, forKey: .kind),
            size: try container.decodeIfPresent(Int64.self, forKey: .size),
            modificationDate: try container.decodeIfPresent(Date.self, forKey: .modificationDate),
            creationDate: try container.decodeIfPresent(Date.self, forKey: .creationDate),
            uti: try container.decodeIfPresent(String.self, forKey: .uti),
            mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType),
            fileExtension: try container.decodeIfPresent(String.self, forKey: .fileExtension),
            isHidden: try container.decode(Bool.self, forKey: .isHidden),
            isReadable: try container.decode(Bool.self, forKey: .isReadable),
            isWritable: try container.decode(Bool.self, forKey: .isWritable),
            tags: try container.decodeIfPresent([FileTag].self, forKey: .tags) ?? [],
            tagScopes: try container.decodeIfPresent([FileTagScope].self, forKey: .tagScopes) ?? [],
            supportsTagEditing: try container.decodeIfPresent(Bool.self, forKey: .supportsTagEditing) ?? false
        )
    }

    public var isDirectory: Bool { kind == .directory || kind == .package }
    public var localURL: URL? { location.localURL }
}
