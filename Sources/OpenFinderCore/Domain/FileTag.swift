import Foundation

public enum FileTagScopeKind: String, Codable, Hashable, Sendable, CaseIterable {
    case local
    case personal
    case team
}

public struct FileTagScopeCapabilities: Codable, Hashable, Sendable {
    public let canAssociate: Bool
    public let canCreate: Bool
    public let canRename: Bool
    public let canUpdateStyle: Bool
    public let canDelete: Bool
    public let canOrganizeGroups: Bool

    public init(
        canAssociate: Bool = false,
        canCreate: Bool = false,
        canRename: Bool = false,
        canUpdateStyle: Bool = false,
        canDelete: Bool = false,
        canOrganizeGroups: Bool = false
    ) {
        self.canAssociate = canAssociate
        self.canCreate = canCreate
        self.canRename = canRename
        self.canUpdateStyle = canUpdateStyle
        self.canDelete = canDelete
        self.canOrganizeGroups = canOrganizeGroups
    }

    public static let none = Self()
}

public struct FileTagScope: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: FileTagScopeKind
    public let displayName: String
    public let capabilities: FileTagScopeCapabilities

    public init(
        id: String,
        kind: FileTagScopeKind,
        displayName: String,
        capabilities: FileTagScopeCapabilities = .none
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.capabilities = capabilities
    }

    public static let local = Self(
        id: "local",
        kind: .local,
        displayName: "Local",
        capabilities: .init(canAssociate: true, canCreate: true)
    )
}

public enum FileTagColor: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    public init(kodboxStyle: String?) {
        switch kodboxStyle {
        case "label-red-normal": self = .red
        case "label-orange-normal": self = .orange
        case "label-yellow-normal": self = .yellow
        case "label-green-normal": self = .green
        case "label-blue-normal": self = .blue
        case "label-purple-normal": self = .purple
        case "label-gray-normal", "label-grey-normal", "label-black-normal": self = .gray
        default: self = .none
        }
    }
}

public struct FileTagGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let scopeID: String
    public let name: String

    public init(id: String, scopeID: String, name: String) {
        self.id = id
        self.scopeID = scopeID
        self.name = name
    }
}

public struct FileTag: Codable, Hashable, Sendable {
    public let id: String
    public let scopeID: String
    public let name: String
    public let color: FileTagColor
    public let groupID: String?

    public init(
        id: String,
        scopeID: String,
        name: String,
        color: FileTagColor = .none,
        groupID: String? = nil
    ) {
        self.id = id
        self.scopeID = scopeID
        self.name = name
        self.color = color
        self.groupID = groupID
    }

    public static func local(name: String) -> Self {
        Self(id: "local:\(name)", scopeID: FileTagScope.local.id, name: name)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scopeID == rhs.scopeID && lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(scopeID)
        hasher.combine(id)
    }
}

public struct FileTagCatalog: Codable, Hashable, Sendable {
    public let scopes: [FileTagScope]
    public let groups: [FileTagGroup]
    public let tags: [FileTag]
    public let providerState: [String: String]?

    public init(
        scopes: [FileTagScope],
        groups: [FileTagGroup] = [],
        tags: [FileTag] = [],
        providerState: [String: String]? = nil
    ) {
        self.scopes = scopes
        self.groups = groups
        self.tags = tags
        self.providerState = providerState
    }
}

public struct FileTagChangeSet: Codable, Hashable, Sendable {
    public let additions: [FileTag]
    public let removals: [FileTag]

    public init(add: [FileTag] = [], remove: [FileTag] = []) {
        let normalizedRemovals = Self.uniqueByIdentity(remove)
        let removalIdentities = Set(normalizedRemovals)
        additions = Self.uniqueByIdentity(add).filter { !removalIdentities.contains($0) }
        removals = normalizedRemovals
    }

    public var isEmpty: Bool {
        additions.isEmpty && removals.isEmpty
    }

    private static func uniqueByIdentity(_ tags: [FileTag]) -> [FileTag] {
        var seen = Set<FileTag>()
        return tags.filter { seen.insert($0).inserted }
    }
}

public enum FileTagCatalogMutation: Codable, Hashable, Sendable {
    case createTag(name: String, groupID: String?)
    case renameTag(id: String, name: String)
    case updateTagStyle(id: String, color: FileTagColor)
    case moveTag(id: String, groupID: String?)
    case deleteTag(id: String)
}

public struct TagApplyFailure: Codable, Hashable, Sendable {
    public let itemID: String
    public let tag: FileTag?
    public let message: String

    public init(itemID: String, tag: FileTag? = nil, message: String) {
        self.itemID = itemID
        self.tag = tag
        self.message = message
    }
}

public struct TagApplyResult: Codable, Hashable, Sendable {
    public let appliedItemIDs: [String]
    public let failures: [TagApplyFailure]

    public init(appliedItemIDs: [String] = [], failures: [TagApplyFailure] = []) {
        self.appliedItemIDs = appliedItemIDs
        self.failures = failures
    }

    public var hasFailures: Bool {
        !failures.isEmpty
    }
}

public protocol TagProvider: Sendable {
    func tagCatalog(for location: Location) async throws -> FileTagCatalog
    func apply(_ changes: FileTagChangeSet, to items: [FileItem]) async throws -> TagApplyResult
    func mutate(_ mutation: FileTagCatalogMutation, in scope: FileTagScope) async throws -> FileTagCatalog
}
