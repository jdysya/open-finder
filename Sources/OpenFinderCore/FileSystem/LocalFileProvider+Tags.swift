import Foundation

extension LocalFileProvider: TagProvider {
    public func tagCatalog(for location: Location) async throws -> FileTagCatalog {
        _ = try localURL(for: location)
        let items = try await list(
            location,
            options: .init(showHiddenFiles: true, sort: .name(ascending: true))
        )
        var seen = Set<FileTag>()
        let tags = items.flatMap(\.tags).filter { seen.insert($0).inserted }
        return FileTagCatalog(scopes: [.local], tags: tags)
    }

    public func apply(_ changes: FileTagChangeSet, to items: [FileItem]) async throws -> TagApplyResult {
        guard !changes.isEmpty else { return TagApplyResult() }

        let localAdditions = changes.additions.filter { $0.scopeID == FileTagScope.local.id }
        let localRemovals = changes.removals.filter { $0.scopeID == FileTagScope.local.id }
        let unsupportedTags = changes.additions.filter { $0.scopeID != FileTagScope.local.id }
            + changes.removals.filter { $0.scopeID != FileTagScope.local.id }
        let invalidTags = localAdditions.filter { $0.name.isEmpty }
            + localRemovals.filter { $0.name.isEmpty }
        let validAdditions = localAdditions.filter { !$0.name.isEmpty }
        let validRemovals = localRemovals.filter { !$0.name.isEmpty }

        return try await Self.runFileIO {
            var appliedItemIDs: [String] = []
            var failures: [TagApplyFailure] = []

            for item in items {
                for tag in unsupportedTags + invalidTags {
                    failures.append(
                        TagApplyFailure(
                            itemID: item.id,
                            tag: tag,
                            message: tag.scopeID == FileTagScope.local.id
                                ? "A Finder tag name cannot be empty"
                                : "This provider only supports local Finder tags"
                        )
                    )
                }

                guard item.location.localURL != nil else {
                    failures.append(TagApplyFailure(itemID: item.id, message: "Item is not a local file"))
                    continue
                }
                guard item.isWritable else {
                    failures.append(TagApplyFailure(itemID: item.id, message: "Item is read-only"))
                    continue
                }
                guard !validAdditions.isEmpty || !validRemovals.isEmpty else { continue }

                do {
                    let url = try localURL(for: item.location)
                    let values = try url.resourceValues(forKeys: [.isWritableKey, .tagNamesKey])
                    guard values.isWritable ?? FileManager.default.isWritableFile(atPath: url.path) else {
                        failures.append(TagApplyFailure(itemID: item.id, message: "Item is read-only"))
                        continue
                    }

                    let names = updatedTagNames(
                        existing: values.tagNames ?? [],
                        additions: validAdditions.map(\.name),
                        removals: validRemovals.map(\.name)
                    )
                    if names != (values.tagNames ?? []) {
                        try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
                    }
                    appliedItemIDs.append(item.id)
                } catch {
                    failures.append(TagApplyFailure(itemID: item.id, message: error.localizedDescription))
                }
            }

            return TagApplyResult(appliedItemIDs: appliedItemIDs, failures: failures)
        }
    }

    public func mutate(_ mutation: FileTagCatalogMutation, in scope: FileTagScope) async throws -> FileTagCatalog {
        guard scope.id == FileTagScope.local.id, scope.kind == .local else {
            throw OpenFinderError.operationFailed("This provider only supports the local Finder tag scope")
        }
        throw OpenFinderError.operationFailed("Finder does not expose a public tag catalog mutation API")
    }

    private func updatedTagNames(existing: [String], additions: [String], removals: [String]) -> [String] {
        let removedNames = Set(removals)
        var seen = Set<String>()
        var result = existing.filter { !removedNames.contains($0) && seen.insert($0).inserted }
        for name in additions where seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }
}
