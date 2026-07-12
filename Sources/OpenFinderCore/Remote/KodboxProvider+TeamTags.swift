import Foundation

extension KodboxProvider {
    func teamTagCatalog(groupID: String, scope: FileTagScope) async throws -> FileTagCatalog {
        let payload: KodboxTeamTagCatalogPayload = try await session.perform(
            .tagGroupGet,
            form: ["groupID": try validTeamIdentifier(groupID)],
            response: KodboxTeamTagCatalogPayload.self
        )
        return payload.catalog(in: scope)
    }

    func mutateTeamTagCatalog(_ mutation: FileTagCatalogMutation, in scope: FileTagScope) async throws -> FileTagCatalog {
        let groupID = try teamGroupID(from: scope)
        guard canManage(mutation, in: scope.capabilities) else {
            throw OpenFinderError.operationFailed("Kodbox team tag catalog management is not permitted")
        }
        let current: KodboxTeamTagCatalogPayload = try await session.perform(
            .tagGroupGet,
            form: ["groupID": groupID],
            response: KodboxTeamTagCatalogPayload.self
        )
        let diff = try current.minimalDiff(for: mutation)
        let returned: KodboxTeamTagCatalogPayload = try await session.perform(
            .tagGroupSet,
            form: ["groupID": groupID, "diff": try diff.encodedString()],
            response: KodboxTeamTagCatalogPayload.self
        )
        let providerState: [String: String]?
        if case .deleteTag(let id) = mutation {
            providerState = [
                "kodbox.team.deleteRemovesAssociations": "true",
                "kodbox.team.deletedTagID": id
            ]
        } else {
            providerState = nil
        }
        return returned.catalog(in: scope, providerState: providerState)
    }

    func teamGroupID(for location: Location) throws -> String? {
        guard case let .remote(remote) = location,
              remote.connectorID == .kodbox,
              remote.accountID == accountID
        else {
            throw OpenFinderError.operationFailed("Location does not belong to this Kodbox account")
        }
        if let scope = teamScopesByPath[remote.path.identifier] {
            return try teamGroupID(from: scope)
        }
        return teamGroupID(in: remote.path.identifier)
    }

    func cachedTeamScope(for location: Location, groupID: String) -> FileTagScope {
        guard case let .remote(remote) = location else {
            return defaultTeamScope(groupID: groupID)
        }
        return teamScopesByPath[remote.path.identifier] ?? defaultTeamScope(groupID: groupID)
    }

    func teamAssociationForm(for item: FileItem, tag: FileTag) throws -> [String: String] {
        let groupID = try teamGroupID(from: tag.scopeID)
        guard item.isWritable, item.supportsTagEditing else {
            throw OpenFinderError.operationFailed("Item is read-only")
        }
        guard case let .remote(remote) = item.location,
              remote.connectorID == .kodbox,
              remote.accountID == accountID
        else {
            throw OpenFinderError.operationFailed("Item does not belong to this Kodbox account")
        }
        guard item.tagScopes.contains(where: {
            $0.kind == .team && $0.id == tag.scopeID && $0.capabilities.canAssociate
        }) else {
            throw OpenFinderError.operationFailed("Item cannot use this Kodbox team tag scope")
        }
        let itemGroupID = teamGroupID(in: remote.path.identifier)
            ?? teamScopesByPath[remote.path.identifier].flatMap { try? teamGroupID(from: $0) }
        guard itemGroupID == groupID else {
            throw OpenFinderError.operationFailed("Item does not belong to the Kodbox team tag group")
        }
        let path = remote.path.identifier
        guard path != Self.syntheticRootIdentifier,
              path != "/",
              !path.contains(","),
              !path.contains("__*@*__")
        else {
            throw OpenFinderError.operationFailed("Kodbox tag association path is unsafe")
        }
        return [
            "groupID": groupID,
            "tagID": try validTeamIdentifier(tag.id),
            "files": path
        ]
    }

    func teamGroupID(from scope: FileTagScope) throws -> String {
        guard scope.kind == .team else {
            throw OpenFinderError.operationFailed("Tag scope is not a Kodbox team scope")
        }
        return try teamGroupID(from: scope.id)
    }

    func teamGroupID(from scopeID: String) throws -> String {
        let prefix = "kodbox:\(accountID.uuidString):team:"
        guard scopeID.hasPrefix(prefix) else {
            throw OpenFinderError.operationFailed("Tag does not belong to this Kodbox team scope")
        }
        return try validTeamIdentifier(String(scopeID.dropFirst(prefix.count)))
    }

    private func defaultTeamScope(groupID: String) -> FileTagScope {
        FileTagScope(
            id: "kodbox:\(accountID.uuidString):team:\(groupID)",
            kind: .team,
            displayName: "Kodbox Team \(groupID)"
        )
    }

    private func teamGroupID(in path: String) -> String? {
        guard let range = path.range(of: "{group:"),
              let end = path[range.upperBound...].firstIndex(of: "}")
        else {
            return nil
        }
        let identifier = String(path[range.upperBound..<end])
        return (try? validTeamIdentifier(identifier))
    }

    private func validTeamIdentifier(_ identifier: String) throws -> String {
        guard let value = Int(identifier), value > 0, String(value) == identifier else {
            throw OpenFinderError.operationFailed("Kodbox team identifier is invalid")
        }
        return identifier
    }

    private func canManage(_ mutation: FileTagCatalogMutation, in capabilities: FileTagScopeCapabilities) -> Bool {
        switch mutation {
        case .createTag:
            capabilities.canCreate
        case .renameTag:
            capabilities.canRename
        case .updateTagStyle:
            capabilities.canUpdateStyle
        case .moveTag:
            capabilities.canOrganizeGroups
        case .deleteTag:
            capabilities.canDelete
        }
    }
}
