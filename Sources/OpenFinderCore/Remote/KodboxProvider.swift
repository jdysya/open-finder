import Foundation

public actor KodboxProvider: RemoteProvider {
    public static let syntheticRootIdentifier = "kodbox:user-space-root"

    let session: KodboxAPISession
    let accountID: UUID
    var teamScopesByPath: [String: FileTagScope] = [:]

    public init(session: KodboxAPISession, accountID: UUID = UUID()) {
        self.session = session
        self.accountID = accountID
    }

    public func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        if directory.identifier == Self.syntheticRootIdentifier {
            return try await syntheticRootListing(current: directory)
        }
        guard directory.identifier != "/" else {
            throw OpenFinderError.operationFailed("Kodbox server root cannot be listed")
        }

        let payload: KodboxListPayload = try await session.perform(
            .explorerList,
            form: ["path": directory.identifier],
            response: KodboxListPayload.self
        )
        let personalScope = personalTagScope
        let folders = payload.folderList.map {
            $0.remoteItem(
                parentDisplayPath: directory.displayPath,
                kind: .directory,
                personalScope: personalScope,
                accountID: accountID
            )
        }
        let files = payload.fileList.map {
            $0.remoteItem(
                parentDisplayPath: directory.displayPath,
                kind: .file,
                personalScope: personalScope,
                accountID: accountID
            )
        }
        let items = folders + files
        let teamScopes = items.compactMap { item in
            item.tagScopes.first(where: { $0.kind == .team })
        }
        for item in items {
            if let teamScope = item.tagScopes.first(where: { $0.kind == .team }) {
                teamScopesByPath[item.remotePath.identifier] = teamScope
            }
        }
        if let directoryScope = teamScopes.first(where: { $0.capabilities.canCreate }) ?? teamScopes.first {
            teamScopesByPath[directory.identifier] = directoryScope
        }
        return RemoteDirectoryListing(
            current: directory,
            parent: nil,
            items: items,
            capabilities: .init(isReadable: true, isWritable: true, supportsTags: true)
        )
    }

    public func createDirectory(in parent: RemotePath, named name: String) async throws {
        try Self.requireWritable(parent)
        let _: KodboxMutationPayload = try await session.perform(
            .explorerMkdir,
            form: ["path": Self.childIdentifier(in: parent, named: name)],
            response: KodboxMutationPayload.self
        )
    }

    public func createFile(in parent: RemotePath, named name: String) async throws {
        try Self.requireWritable(parent)
        let _: KodboxMutationPayload = try await session.perform(
            .explorerMkfile,
            form: ["path": Self.childIdentifier(in: parent, named: name)],
            response: KodboxMutationPayload.self
        )
    }

    public func rename(item: RemotePath, named name: String) async throws {
        try Self.requireWritable(item)
        let _: KodboxMutationPayload = try await session.perform(
            .explorerRename,
            form: ["path": item.identifier, "newName": name],
            response: KodboxMutationPayload.self
        )
    }

    public func delete(item: RemotePath) async throws {
        try Self.requireWritable(item)
        let _: KodboxMutationPayload = try await session.perform(
            .explorerDelete,
            form: ["dataArr": try Self.mutationItem(path: item.identifier)],
            response: KodboxMutationPayload.self
        )
    }

    public func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {
        try Self.requireWritable(item)
        try Self.requireWritable(destination)
        let _: KodboxMutationPayload = try await session.perform(
            .explorerMove,
            form: [
                "dataArr": try Self.mutationItem(path: item.identifier, name: name),
                "path": destination.identifier
            ],
            response: KodboxMutationPayload.self
        )
    }

    public func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {
        try Self.requireWritable(item)
        try Self.requireWritable(destination)
        let _: KodboxMutationPayload = try await session.perform(
            .explorerCopy,
            form: [
                "dataArr": try Self.mutationItem(path: item.identifier, name: name),
                "path": destination.identifier
            ],
            response: KodboxMutationPayload.self
        )
    }

    public func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID {
        try Self.requireWritable(parent)
        try Task.checkCancellation()
        try await session.upload(localURL: localURL, to: parent.identifier, named: name)
        try Task.checkCancellation()
        return UUID()
    }

    public func download(item: RemotePath, to localURL: URL) async throws -> TaskID {
        try Self.requireWritable(item)
        try Task.checkCancellation()
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: localURL.path) else {
            throw OpenFinderError.operationFailed("Local destination already exists: \(localURL.path)")
        }

        let temporaryDestination = localURL.deletingLastPathComponent()
            .appendingPathComponent(".openfinder-kodbox-download-\(UUID().uuidString)")
        defer {
            if fileManager.fileExists(atPath: temporaryDestination.path) {
                try? fileManager.removeItem(at: temporaryDestination)
            }
        }

        let downloadedURL = try await session.download(from: item.identifier)
        try Task.checkCancellation()
        try fileManager.copyItem(at: downloadedURL, to: temporaryDestination)
        try Task.checkCancellation()
        guard !fileManager.fileExists(atPath: localURL.path) else {
            throw OpenFinderError.operationFailed("Local destination already exists: \(localURL.path)")
        }
        try fileManager.moveItem(at: temporaryDestination, to: localURL)
        return UUID()
    }

    private func syntheticRootListing(current: RemotePath) async throws -> RemoteDirectoryListing {
        let options: KodboxOptions = try await session.perform(.options, form: [:], response: KodboxOptions.self)
        var roots = [(name: "Personal", identifier: options.user.myhome)]
        if let desktop = options.user.desktop, desktop != options.user.myhome {
            roots.append((name: "Desktop", identifier: desktop))
        }
        roots += [
            (name: "Team Space", identifier: "{groupRootSelf}"),
            (name: "Shared with Me", identifier: "{shareToMe}"),
            (name: "My Shares", identifier: "{userShare}"),
            (name: "Favorites", identifier: "{userFav}")
        ]

        return RemoteDirectoryListing(
            current: current,
            parent: nil,
            items: roots.map(Self.navigationItem),
            capabilities: .init(isReadable: true, isWritable: false)
        )
    }

    private static func navigationItem(name: String, identifier: String) -> RemoteItem {
        RemoteItem(
            id: "kodbox:\(identifier)",
            name: name,
            path: .init(identifier: identifier, displayPath: "/\(name)"),
            kind: .directory,
            size: nil,
            modificationDate: nil,
            etag: nil,
            mimeType: nil,
            isReadable: true,
            isWritable: false
        )
    }

    private static func requireWritable(_ path: RemotePath) throws {
        guard path.identifier != syntheticRootIdentifier, path.identifier != "/" else {
            throw OpenFinderError.operationFailed("Kodbox navigation roots are read-only")
        }
    }

    private static func childIdentifier(in parent: RemotePath, named name: String) -> String {
        parent.identifier.hasSuffix("/") ? parent.identifier + name : parent.identifier + "/" + name
    }

    private static func mutationItem(path: String, name: String? = nil) throws -> String {
        let encodedPath = try jsonString(path)
        if let name {
            return "[{\"path\":\(encodedPath),\"name\":\(try jsonString(name))}]"
        }
        return "[{\"path\":\(encodedPath)}]"
    }

    private static func jsonString(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    var personalTagScope: FileTagScope {
        .init(
            id: "kodbox:\(accountID.uuidString):personal",
            kind: .personal,
            displayName: "Kodbox Personal",
            capabilities: .init(
                canAssociate: true,
                canCreate: true,
                canRename: true,
                canUpdateStyle: true,
                canDelete: true
            )
        )
    }
}

private struct KodboxOptions: Decodable, Sendable {
    let user: User

    struct User: Decodable, Sendable {
        let myhome: String
        let desktop: String?
    }
}

private struct KodboxListPayload: Decodable, Sendable {
    let folderList: [KodboxListItem]
    let fileList: [KodboxListItem]
}

private struct KodboxListItem: Decodable, Sendable {
    let name: String
    let path: String
    let size: Int64?
    let modifyTime: TimeInterval?
    let sourceInfo: KodboxListSourceInfo?
    let targetType: String?
    let targetID: String?
    let canWrite: Bool?

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case size
        case modifyTime
        case sourceInfo
        case targetType
        case targetID
        case canWrite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        modifyTime = try container.decodeIfPresent(TimeInterval.self, forKey: .modifyTime)
        sourceInfo = try? container.decodeIfPresent(KodboxListSourceInfo.self, forKey: .sourceInfo)
        targetType = try? container.decodeIfPresent(String.self, forKey: .targetType)
        targetID = Self.identifier(from: container, key: .targetID)
        canWrite = try? container.decodeIfPresent(Bool.self, forKey: .canWrite)
    }

    func remoteItem(
        parentDisplayPath: String,
        kind: FileKind,
        personalScope: FileTagScope,
        accountID: UUID
    ) -> RemoteItem {
        let displayPath = parentDisplayPath == "/"
            ? "/\(name)"
            : "\(parentDisplayPath)/\(name)"
        let isWritable = canWrite ?? true
        let teamScope = self.teamScope(accountID: accountID, isWritable: isWritable)
        let tags: [FileTag]
        let tagScopes: [FileTagScope]
        if let teamScope {
            tags = sourceInfo?.teamTags(in: teamScope) ?? []
            tagScopes = [teamScope]
        } else {
            tags = sourceInfo?.personalTags(in: personalScope) ?? []
            tagScopes = [personalScope]
        }
        return RemoteItem(
            id: "kodbox:\(path)",
            name: name,
            path: .init(identifier: path, displayPath: displayPath),
            kind: kind,
            size: size,
            modificationDate: modifyTime.map(Date.init(timeIntervalSince1970:)),
            etag: nil,
            mimeType: nil,
            isReadable: true,
            isWritable: isWritable,
            tags: tags,
            tagScopes: tagScopes,
            supportsTagEditing: tagScopes.contains { $0.capabilities.canAssociate }
        )
    }

    private func teamScope(accountID: UUID, isWritable: Bool) -> FileTagScope? {
        guard targetType == "group", let targetID, Self.isValidGroupID(targetID) else {
            return nil
        }
        let canManage = sourceInfo?.isGroupRoot ?? false
        return FileTagScope(
            id: "kodbox:\(accountID.uuidString):team:\(targetID)",
            kind: .team,
            displayName: "Kodbox Team \(targetID)",
            capabilities: .init(
                canAssociate: isWritable,
                canCreate: canManage,
                canRename: canManage,
                canDelete: canManage,
                canOrganizeGroups: canManage
            )
        )
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

    private static func isValidGroupID(_ value: String) -> Bool {
        guard let identifier = Int(value), identifier > 0 else { return false }
        return String(identifier) == value
    }
}

private struct KodboxListSourceInfo: Decodable, Sendable {
    private let tagInfo: [KodboxListTag]
    private let groupTagInfo: [KodboxGroupListTag]
    private let groupTagList: [KodboxGroupListTag]
    let isGroupRoot: Bool
    private let isGroupHasTag: Bool

    private enum CodingKeys: String, CodingKey { case tagInfo, groupTagInfo, isGroupRoot, isGroupHasTag, groupTagList }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagInfo = Self.decodeArray(from: container, key: .tagInfo, element: KodboxListTag.self)
        groupTagInfo = Self.decodeArray(from: container, key: .groupTagInfo, element: KodboxGroupListTag.self)
        groupTagList = Self.decodeArray(from: container, key: .groupTagList, element: KodboxGroupListTag.self)
        isGroupRoot = (try? container.decodeIfPresent(Bool.self, forKey: .isGroupRoot)) ?? false
        isGroupHasTag = (try? container.decodeIfPresent(Bool.self, forKey: .isGroupHasTag)) ?? false
    }

    func personalTags(in scope: FileTagScope) -> [FileTag] {
        var seen = Set<FileTag>()
        return tagInfo.compactMap { $0.fileTag(in: scope) }.filter { seen.insert($0).inserted }
    }

    func teamTags(in scope: FileTagScope?) -> [FileTag] {
        guard let scope else { return [] }
        var seen = Set<FileTag>()
        return groupTagInfo.compactMap { $0.fileTag(in: scope) }.filter { seen.insert($0).inserted }
    }

    private static func decodeArray<Element: Decodable>(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        element: Element.Type
    ) -> [Element] {
        guard var entries = try? container.nestedUnkeyedContainer(forKey: key) else {
            return []
        }
        var parsed: [Element] = []
        while !entries.isAtEnd {
            guard let entry = try? entries.decode(Element.self) else { break }
            parsed.append(entry)
        }
        return parsed
    }
}

private struct KodboxListTag: Decodable, Sendable {
    private let id: String?
    private let name: String?
    private let style: String?

    private enum CodingKeys: String, CodingKey { case tagID, name, style }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil
            name = nil
            style = nil
            return
        }
        if let identifier = try? container.decode(String.self, forKey: .tagID) {
            id = identifier
        } else if let identifier = try? container.decode(Int.self, forKey: .tagID) {
            id = String(identifier)
        } else {
            id = nil
        }
        name = try? container.decode(String.self, forKey: .name)
        style = try? container.decode(String.self, forKey: .style)
    }

    func fileTag(in scope: FileTagScope) -> FileTag? {
        guard let id, id != "0", let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return FileTag(id: id, scopeID: scope.id, name: name, color: .init(kodboxStyle: style))
    }
}

private struct KodboxGroupListTag: Decodable, Sendable {
    private let id: String?
    private let name: String?
    private let groupInfo: KodboxGroupListTagGroup?

    private enum CodingKeys: String, CodingKey { case id, name, groupInfo }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil
            name = nil
            groupInfo = nil
            return
        }
        id = Self.identifier(from: container, key: .id)
        name = try? container.decode(String.self, forKey: .name)
        groupInfo = try? container.decode(KodboxGroupListTagGroup.self, forKey: .groupInfo)
    }

    func fileTag(in scope: FileTagScope) -> FileTag? {
        guard let id, id != "0", let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return FileTag(id: id, scopeID: scope.id, name: name, groupID: groupInfo?.id)
    }

    private static func identifier(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let id = try? container.decode(String.self, forKey: key) {
            return id
        }
        if let id = try? container.decode(Int.self, forKey: key) {
            return String(id)
        }
        return nil
    }
}

private struct KodboxGroupListTagGroup: Decodable, Sendable {
    let id: String?

    private enum CodingKeys: String, CodingKey { case id }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil
            return
        }
        if let identifier = try? container.decode(String.self, forKey: .id) {
            id = identifier
        } else if let identifier = try? container.decode(Int.self, forKey: .id) {
            id = String(identifier)
        } else {
            id = nil
        }
    }
}

private struct KodboxMutationPayload: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}
