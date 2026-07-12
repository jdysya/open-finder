import Foundation

extension KodboxProvider: TagProvider {
    public func tagCatalog(for location: Location) async throws -> FileTagCatalog {
        if let groupID = try teamGroupID(for: location) {
            return try await teamTagCatalog(
                groupID: groupID,
                scope: cachedTeamScope(for: location, groupID: groupID)
            )
        }
        try requirePersonalLocation(location)
        let payload: KodboxPersonalTagCatalogPayload = try await session.perform(
            .tagGet,
            form: [:],
            response: KodboxPersonalTagCatalogPayload.self
        )
        return payload.catalog(in: personalTagScope)
    }

    public func apply(_ changes: FileTagChangeSet, to items: [FileItem]) async throws -> TagApplyResult {
        guard !changes.isEmpty else { return TagApplyResult() }

        let operations = changes.additions.map { KodboxTagAssociation(tag: $0, isAddition: true) }
            + changes.removals.map { KodboxTagAssociation(tag: $0, isAddition: false) }
        var appliedItemIDs: [String] = []
        var failures: [TagApplyFailure] = []

        for item in items {
            let scopeIDs = Set(operations.map(\.tag.scopeID))
            guard scopeIDs.count == 1 else {
                failures += operations.map {
                    TagApplyFailure(
                        itemID: item.id,
                        tag: $0.tag,
                        message: "Tags from different Kodbox scopes cannot be applied together"
                    )
                }
                continue
            }

            var preparedOperations: [(KodboxTagAssociation, KodboxTagAssociationRequest)] = []
            var hasPreflightFailure = false
            for operation in operations {
                do {
                    preparedOperations.append((operation, try tagAssociationRequest(for: item, operation: operation)))
                } catch {
                    hasPreflightFailure = true
                    failures.append(
                        TagApplyFailure(
                            itemID: item.id,
                            tag: operation.tag,
                            message: error.localizedDescription
                        )
                    )
                }
            }
            guard !hasPreflightFailure else { continue }

            var itemSucceeded = true
            for (operation, request) in preparedOperations {
                do {
                    let _: KodboxPersonalTagMutationPayload = try await session.perform(
                        request.endpoint,
                        form: request.form,
                        response: KodboxPersonalTagMutationPayload.self
                    )
                } catch {
                    itemSucceeded = false
                    failures.append(
                        TagApplyFailure(
                            itemID: item.id,
                            tag: operation.tag,
                            message: error.localizedDescription
                        )
                    )
                }
            }
            if itemSucceeded {
                appliedItemIDs.append(item.id)
            }
        }

        return TagApplyResult(appliedItemIDs: appliedItemIDs, failures: failures)
    }

    public func mutate(_ mutation: FileTagCatalogMutation, in scope: FileTagScope) async throws -> FileTagCatalog {
        if scope.kind == .team {
            return try await mutateTeamTagCatalog(mutation, in: scope)
        }
        try requirePersonalScope(scope)

        let payload: KodboxPersonalTagCatalogPayload
        switch mutation {
        case .createTag(let name, let groupID):
            guard groupID == nil else {
                throw OpenFinderError.operationFailed("Kodbox personal tags do not support groups")
            }
            let name = try nonEmptyTagName(name)
            payload = try await session.perform(
                .tagAdd,
                form: ["name": name, "style": KodboxPersonalTagStyle.encoded(.none)],
                response: KodboxPersonalTagCatalogPayload.self
            )
        case .renameTag(let id, let name):
            payload = try await session.perform(
                .tagEdit,
                form: ["tagID": try validPersonalTagID(id), "name": try nonEmptyTagName(name)],
                response: KodboxPersonalTagCatalogPayload.self
            )
        case .updateTagStyle(let id, let color):
            payload = try await session.perform(
                .tagEdit,
                form: ["tagID": try validPersonalTagID(id), "style": KodboxPersonalTagStyle.encoded(color)],
                response: KodboxPersonalTagCatalogPayload.self
            )
        case .moveTag:
            throw OpenFinderError.operationFailed("Kodbox personal tags do not support groups")
        case .deleteTag(let id):
            payload = try await session.perform(
                .tagRemove,
                form: ["tagID": try validPersonalTagID(id)],
                response: KodboxPersonalTagCatalogPayload.self
            )
        }
        return payload.catalog(in: personalTagScope)
    }

    private func requirePersonalLocation(_ location: Location) throws {
        guard case let .remote(remote) = location,
              remote.connectorID == .kodbox,
              remote.accountID == accountID
        else {
            throw OpenFinderError.operationFailed("Location does not belong to this Kodbox account")
        }
    }

    private func requirePersonalScope(_ scope: FileTagScope) throws {
        guard scope.id == personalTagScope.id, scope.kind == .personal else {
            throw OpenFinderError.operationFailed("This provider only supports its personal Kodbox tag scope")
        }
    }

    private func personalAssociationPath(for item: FileItem, tag: FileTag) throws -> String {
        try requirePersonalScopeID(tag.scopeID)
        _ = try validPersonalTagID(tag.id)
        guard item.isWritable, item.supportsTagEditing else {
            throw OpenFinderError.operationFailed("Item is read-only")
        }
        guard case let .remote(remote) = item.location,
              remote.connectorID == .kodbox,
              remote.accountID == accountID
        else {
            throw OpenFinderError.operationFailed("Item does not belong to this Kodbox account")
        }

        let path = remote.path.identifier
        guard path != Self.syntheticRootIdentifier,
              path != "/",
              !path.contains(","),
              !path.contains("__*@*__")
        else {
            throw OpenFinderError.operationFailed("Kodbox tag association path is unsafe")
        }
        return path
    }

    private func requirePersonalScopeID(_ scopeID: String) throws {
        guard scopeID == personalTagScope.id else {
            throw OpenFinderError.operationFailed("Tag does not belong to this Kodbox personal scope")
        }
    }

    private func tagAssociationRequest(
        for item: FileItem,
        operation: KodboxTagAssociation
    ) throws -> KodboxTagAssociationRequest {
        if operation.tag.scopeID == personalTagScope.id {
            return .init(
                endpoint: operation.isAddition ? .tagFilesAdd : .tagFilesRemove,
                form: [
                    "tagID": try validPersonalTagID(operation.tag.id),
                    "files": try personalAssociationPath(for: item, tag: operation.tag)
                ]
            )
        }

        return .init(
            endpoint: operation.isAddition ? .tagGroupFilesAdd : .tagGroupFilesRemove,
            form: try teamAssociationForm(for: item, tag: operation.tag)
        )
    }

    private func validPersonalTagID(_ id: String) throws -> String {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id != "0" else {
            throw OpenFinderError.operationFailed("Kodbox tag identifier is invalid")
        }
        return id
    }

    private func nonEmptyTagName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenFinderError.operationFailed("Kodbox tag name cannot be empty")
        }
        return trimmed
    }
}

private struct KodboxTagAssociation {
    let tag: FileTag
    let isAddition: Bool
}

private struct KodboxTagAssociationRequest {
    let endpoint: KodboxEndpoint
    let form: [String: String]
}

private struct KodboxPersonalTagMutationPayload: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

private struct KodboxPersonalTagCatalogPayload: Decodable, Sendable {
    private let tags: [KodboxPersonalCatalogTag]

    init(from decoder: Decoder) throws {
        var entries = try decoder.unkeyedContainer()
        var parsed: [KodboxPersonalCatalogTag] = []
        while !entries.isAtEnd {
            guard let tag = try? entries.decode(KodboxPersonalCatalogTag.self) else { break }
            parsed.append(tag)
        }
        tags = parsed
    }

    func catalog(in scope: FileTagScope) -> FileTagCatalog {
        var seen = Set<FileTag>()
        let mappedTags = tags.compactMap { $0.fileTag(in: scope) }.filter { seen.insert($0).inserted }
        return FileTagCatalog(scopes: [scope], tags: mappedTags)
    }
}

private struct KodboxPersonalCatalogTag: Decodable, Sendable {
    private let id: String?
    private let name: String?
    private let style: String?

    private enum CodingKeys: String, CodingKey { case id, tagID, name, style }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = Self.identifier(from: container, key: .id) {
            self.id = id
        } else {
            self.id = Self.identifier(from: container, key: .tagID)
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

private enum KodboxPersonalTagStyle {
    static func encoded(_ color: FileTagColor) -> String {
        switch color {
        case .none, .gray:
            "label-grey-normal"
        case .red:
            "label-red-normal"
        case .orange:
            "label-orange-normal"
        case .yellow:
            "label-yellow-normal"
        case .green:
            "label-green-normal"
        case .blue:
            "label-blue-normal"
        case .purple:
            "label-purple-normal"
        }
    }
}
