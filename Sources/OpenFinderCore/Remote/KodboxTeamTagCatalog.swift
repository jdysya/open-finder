import Foundation

struct KodboxTeamTagCatalogPayload: Decodable, Sendable {
    let groups: [KodboxTeamTagGroup]
    let tags: [KodboxTeamCatalogTag]

    private enum CodingKeys: String, CodingKey { case group, list }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = Self.decodeArray(from: container, key: .group, element: KodboxTeamTagGroup.self)
        tags = Self.decodeArray(from: container, key: .list, element: KodboxTeamCatalogTag.self)
    }

    func catalog(in scope: FileTagScope, providerState: [String: String]? = nil) -> FileTagCatalog {
        let groups = groups.compactMap { $0.fileTagGroup(in: scope) }
        let tags = tags.compactMap { $0.fileTag(in: scope) }
        return FileTagCatalog(scopes: [scope], groups: groups, tags: tags, providerState: providerState)
    }

    func minimalDiff(for mutation: FileTagCatalogMutation) throws -> KodboxTeamTagCatalogDiff {
        switch mutation {
        case .createTag(let name, let groupID):
            let groupID = try groupIdentifier(groupID)
            let name = try nonEmptyName(name)
            return .addingTag(name: name, groupID: groupID, after: tags.last?.id ?? "")
        case .renameTag(let id, let name):
            let id = try existingTagIdentifier(id)
            return .editingTag(id: id, key: "name", value: .string(try nonEmptyName(name)))
        case .moveTag(let id, let groupID):
            let id = try existingTagIdentifier(id)
            let groupID = try groupIdentifier(groupID)
            return .editingTag(id: id, key: "group", value: .integer(groupID))
        case .deleteTag(let id):
            return .removingTag(id: try existingTagIdentifier(id))
        case .updateTagStyle:
            throw OpenFinderError.operationFailed("Kodbox team tags do not expose a supported style mutation")
        }
    }

    private func existingTagIdentifier(_ id: String) throws -> String {
        guard tags.contains(where: { $0.id == id }) else {
            throw OpenFinderError.operationFailed("Kodbox team tag does not exist")
        }
        return id
    }

    private func groupIdentifier(_ id: String?) throws -> Int {
        guard let id,
              let integer = Int(id),
              String(integer) == id,
              groups.contains(where: { $0.id == id })
        else {
            throw OpenFinderError.operationFailed("Kodbox team tag group does not exist")
        }
        return integer
    }

    private func nonEmptyName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenFinderError.operationFailed("Kodbox team tag name cannot be empty")
        }
        return trimmed
    }

    private static func decodeArray<Element: Decodable>(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        element: Element.Type
    ) -> [Element] {
        guard var entries = try? container.nestedUnkeyedContainer(forKey: key) else {
            return []
        }
        var values: [Element] = []
        while !entries.isAtEnd {
            guard let value = try? entries.decode(Element.self) else { break }
            values.append(value)
        }
        return values
    }
}

struct KodboxTeamTagGroup: Decodable, Sendable {
    let id: String?
    let name: String?

    private enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil
            name = nil
            return
        }
        id = Self.identifier(from: container, key: .id)
        name = try? container.decode(String.self, forKey: .name)
    }

    func fileTagGroup(in scope: FileTagScope) -> FileTagGroup? {
        guard let id, id != "0", let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return FileTagGroup(id: id, scopeID: scope.id, name: name)
    }

    private static func identifier(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let identifier = try? container.decode(String.self, forKey: key) {
            return identifier
        }
        if let identifier = try? container.decode(Int.self, forKey: key) {
            return String(identifier)
        }
        return nil
    }
}

struct KodboxTeamCatalogTag: Decodable, Sendable {
    let id: String?
    let name: String?
    let groupID: String?

    private enum CodingKeys: String, CodingKey { case id, name, group }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil
            name = nil
            groupID = nil
            return
        }
        id = Self.identifier(from: container, key: .id)
        name = try? container.decode(String.self, forKey: .name)
        groupID = Self.identifier(from: container, key: .group)
    }

    func fileTag(in scope: FileTagScope) -> FileTag? {
        guard let id, id != "0", let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return FileTag(id: id, scopeID: scope.id, name: name, groupID: groupID)
    }

    private static func identifier(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let identifier = try? container.decode(String.self, forKey: key) {
            return identifier
        }
        if let identifier = try? container.decode(Int.self, forKey: key) {
            return String(identifier)
        }
        return nil
    }
}

struct KodboxTeamTagCatalogDiff: Encodable, Sendable {
    let list: KodboxTeamTagArrayDiff

    static func addingTag(name: String, groupID: Int, after identifier: String) -> Self {
        .init(list: .init(add: [.init(beforeID: identifier, value: .init(name: name, groupID: groupID))]))
    }

    static func editingTag(id: String, key: String, value: KodboxTeamTagEditValue) -> Self {
        .init(list: .init(edit: [id: [key: .init(value: value)]]))
    }

    static func removingTag(id: String) -> Self {
        .init(list: .init(remove: [id]))
    }

    func encodedString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

struct KodboxTeamTagArrayDiff: Encodable, Sendable {
    let add: [KodboxTeamTagAddition]
    let remove: [String]
    let edit: [String: [String: KodboxTeamTagEdit]]
    let sort: KodboxTeamTagSort

    init(
        add: [KodboxTeamTagAddition] = [],
        remove: [String] = [],
        edit: [String: [String: KodboxTeamTagEdit]] = [:],
        sort: KodboxTeamTagSort = .unchanged
    ) {
        self.add = add
        self.remove = remove
        self.edit = edit
        self.sort = sort
    }
}

struct KodboxTeamTagAddition: Encodable, Sendable {
    let beforeID: String
    let value: KodboxTeamTagDraft

    private enum CodingKeys: String, CodingKey { case beforeID, value = "val" }
}

struct KodboxTeamTagDraft: Encodable, Sendable {
    let name: String
    let groupID: Int

    private enum CodingKeys: String, CodingKey { case name, groupID = "group" }
}

struct KodboxTeamTagEdit: Encodable, Sendable {
    let type = "edit"
    let value: KodboxTeamTagEditValue

    private enum CodingKeys: String, CodingKey { case type, value = "val" }
}

enum KodboxTeamTagEditValue: Encodable, Sendable {
    case string(String)
    case integer(Int)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        }
    }
}

struct KodboxTeamTagSort: Encodable, Sendable {
    let isChange: Bool
    let idArr: [String]

    static let unchanged = Self(isChange: false, idArr: [])
}
