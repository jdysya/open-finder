import Foundation
import OpenFinderCore

enum FileTagMarker: Equatable, Sendable {
    case neutral
    case canonical(FileTagColor)
    case localLabel(index: Int)
}

struct FileTagCellTag: Equatable, Sendable {
    let tag: FileTag
    let name: String
    let marker: FileTagMarker
}

struct FileTagCellDescriptor: Equatable, Sendable {
    let visible: [FileTagCellTag]
    let overflowCount: Int
    let accessibilityLabel: String
    let toolTip: String?
}

enum FileTagPresentation {
    static func descriptor(
        tags: [FileTag],
        scopes: [FileTagScope] = [],
        catalogOrder: [FileTag] = [],
        maxVisibleTags: Int,
        localLabelIndex: (String) -> Int? = { _ in nil }
    ) -> FileTagCellDescriptor {
        let ordered = orderedTags(tags, scopes: scopes, catalogOrder: catalogOrder)
        let names = ordered.map(\.name)
        let visibleCount = min(max(0, maxVisibleTags), ordered.count)
        var scopeKinds: [String: FileTagScopeKind] = [:]
        for scope in scopes where scopeKinds[scope.id] == nil {
            scopeKinds[scope.id] = scope.kind
        }
        let visible = ordered.prefix(visibleCount).map { tag in
            FileTagCellTag(
                tag: tag,
                name: tag.name,
                marker: marker(for: tag, scopeKinds: scopeKinds, localLabelIndex: localLabelIndex)
            )
        }
        return FileTagCellDescriptor(
            visible: visible,
            overflowCount: ordered.count - visibleCount,
            accessibilityLabel: names.isEmpty ? "标签：无" : "标签：\(names.joined(separator: "、"))",
            toolTip: names.isEmpty ? nil : names.joined(separator: "、")
        )
    }

    private static func orderedTags(
        _ tags: [FileTag],
        scopes: [FileTagScope],
        catalogOrder: [FileTag]
    ) -> [FileTag] {
        var scopeRanks: [String: Int] = [:]
        for scope in scopes where scopeRanks[scope.id] == nil {
            scopeRanks[scope.id] = rank(for: scope.kind)
        }
        var catalogRanks: [FileTag: Int] = [:]
        for (index, tag) in catalogOrder.enumerated() where catalogRanks[tag] == nil {
            catalogRanks[tag] = index
        }
        var seen = Set<FileTag>()
        return tags
            .filter { seen.insert($0).inserted }
            .sorted { lhs, rhs in
                let lhsScopeRank = scopeRanks[lhs.scopeID] ?? (lhs.scopeID == FileTagScope.local.id ? 0 : 3)
                let rhsScopeRank = scopeRanks[rhs.scopeID] ?? (rhs.scopeID == FileTagScope.local.id ? 0 : 3)
                if lhsScopeRank != rhsScopeRank { return lhsScopeRank < rhsScopeRank }

                let lhsCatalogRank = catalogRanks[lhs] ?? Int.max
                let rhsCatalogRank = catalogRanks[rhs] ?? Int.max
                if lhsCatalogRank != rhsCatalogRank { return lhsCatalogRank < rhsCatalogRank }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                if lhs.scopeID != rhs.scopeID { return lhs.scopeID < rhs.scopeID }
                return lhs.id < rhs.id
            }
    }

    private static func rank(for kind: FileTagScopeKind) -> Int {
        switch kind {
        case .local: 0
        case .personal: 1
        case .team: 2
        }
    }

    private static func marker(
        for tag: FileTag,
        scopeKinds: [String: FileTagScopeKind],
        localLabelIndex: (String) -> Int?
    ) -> FileTagMarker {
        let isLocal = scopeKinds[tag.scopeID] == .local || tag.scopeID == FileTagScope.local.id
        if isLocal, let index = localLabelIndex(tag.name) {
            return .localLabel(index: index)
        }
        return tag.color == .none ? .neutral : .canonical(tag.color)
    }
}

enum TagSelectionState: Equatable {
    case empty
    case mixed
    case checked
}

enum TagSelectionReducer {
    static func state(for tag: FileTag, itemTags: [[FileTag]]) -> TagSelectionState {
        guard !itemTags.isEmpty else { return .empty }
        let selectedCount = itemTags.reduce(into: 0) { count, tags in
            if tags.contains(tag) { count += 1 }
        }
        switch selectedCount {
        case 0: return .empty
        case itemTags.count: return .checked
        default: return .mixed
        }
    }

    static func toggling(
        _ tag: FileTag,
        from state: TagSelectionState,
        pending: FileTagChangeSet
    ) -> FileTagChangeSet {
        switch state {
        case .checked:
            return FileTagChangeSet(
                add: pending.additions.filter { $0 != tag },
                remove: pending.removals + [tag]
            )
        case .empty, .mixed:
            return FileTagChangeSet(
                add: pending.additions + [tag],
                remove: pending.removals.filter { $0 != tag }
            )
        }
    }
}
