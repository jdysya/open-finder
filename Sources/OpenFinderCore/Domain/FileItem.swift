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
        isWritable: Bool
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
    }

    public var isDirectory: Bool { kind == .directory || kind == .package }
    public var localURL: URL? { location.localURL }
}
