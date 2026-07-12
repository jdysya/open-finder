import Foundation

public actor KodboxProvider: RemoteProvider {
    public static let syntheticRootIdentifier = "kodbox:user-space-root"

    let session: KodboxAPISession
    let accountID: UUID

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
        return RemoteDirectoryListing(
            current: directory,
            parent: nil,
            items: payload.folderList.map { $0.remoteItem(parentDisplayPath: directory.displayPath, kind: .directory, personalScope: personalScope) }
                + payload.fileList.map { $0.remoteItem(parentDisplayPath: directory.displayPath, kind: .file, personalScope: personalScope) },
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

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case size
        case modifyTime
        case sourceInfo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        modifyTime = try container.decodeIfPresent(TimeInterval.self, forKey: .modifyTime)
        sourceInfo = try? container.decodeIfPresent(KodboxListSourceInfo.self, forKey: .sourceInfo)
    }

    func remoteItem(parentDisplayPath: String, kind: FileKind, personalScope: FileTagScope) -> RemoteItem {
        let displayPath = parentDisplayPath == "/"
            ? "/\(name)"
            : "\(parentDisplayPath)/\(name)"
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
            isWritable: true,
            tags: sourceInfo?.personalTags(in: personalScope) ?? [],
            tagScopes: [personalScope],
            supportsTagEditing: true
        )
    }
}

private struct KodboxListSourceInfo: Decodable, Sendable {
    private let tagInfo: [KodboxListTag]

    private enum CodingKeys: String, CodingKey { case tagInfo }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard var entries = try? container.nestedUnkeyedContainer(forKey: .tagInfo) else {
            tagInfo = []
            return
        }

        var parsed: [KodboxListTag] = []
        while !entries.isAtEnd {
            guard let tag = try? entries.decode(KodboxListTag.self) else { break }
            parsed.append(tag)
        }
        tagInfo = parsed
    }

    func personalTags(in scope: FileTagScope) -> [FileTag] {
        var seen = Set<FileTag>()
        return tagInfo.compactMap { $0.fileTag(in: scope) }.filter { seen.insert($0).inserted }
    }
}

private struct KodboxListTag: Decodable, Sendable {
    private let id: String?
    private let name: String?
    private let style: String?

    private enum CodingKeys: String, CodingKey { case tagID, name, style }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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

private struct KodboxMutationPayload: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}
