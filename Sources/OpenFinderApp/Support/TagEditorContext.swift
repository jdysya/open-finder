import Combine
import Foundation
import OpenFinderCore

enum TagEditorOperationState: Equatable {
    case idle
    case loadingCatalog
    case applyingChanges
    case mutatingCatalog
}

struct TagEditorScopeSection: Equatable {
    let scope: FileTagScope
    let tags: [FileTag]
}

enum TagEditorPresentation {
    static func sections(
        in catalog: FileTagCatalog,
        searchText: String,
        pendingAdditions: [FileTag] = []
    ) -> [TagEditorScopeSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var seenTags = Set<FileTag>()
        let visibleTags = (catalog.tags + pendingAdditions).filter { seenTags.insert($0).inserted }
        return orderedScopes(in: catalog).compactMap { scope in
            let tags = visibleTags.filter { tag in
                guard tag.scopeID == scope.id else { return false }
                return query.isEmpty || tag.name.localizedCaseInsensitiveContains(query)
            }
            guard query.isEmpty || !tags.isEmpty else { return nil }
            return TagEditorScopeSection(scope: scope, tags: tags)
        }
    }

    static func creationScopes(
        in catalog: FileTagCatalog,
        searchText: String,
        pendingAdditions: [FileTag] = []
    ) -> [FileTagScope] {
        let name = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        let hasExactMatch = (catalog.tags + pendingAdditions).contains {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        guard !hasExactMatch else { return [] }
        return orderedScopes(in: catalog).filter(\.capabilities.canCreate)
    }

    static func manageableScopes(in catalog: FileTagCatalog) -> [FileTagScope] {
        orderedScopes(in: catalog).filter { scope in
            guard scope.kind != .local else { return false }
            let capabilities = scope.capabilities
            return capabilities.canCreate
                || capabilities.canRename
                || capabilities.canUpdateStyle
                || capabilities.canDelete
                || capabilities.canOrganizeGroups
        }
    }

    static func newlyCreatedTag(
        in catalog: FileTagCatalog,
        previously existingTags: Set<FileTag>,
        scopeID: String,
        name: String
    ) -> FileTag? {
        catalog.tags.first {
            !existingTags.contains($0)
                && $0.scopeID == scopeID
                && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func orderedScopes(in catalog: FileTagCatalog) -> [FileTagScope] {
        var seen = Set<String>()
        return catalog.scopes
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let lhsRank = rank(lhs.kind)
                let rhsRank = rank(rhs.kind)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
                return lhs.id < rhs.id
            }
    }

    private static func rank(_ kind: FileTagScopeKind) -> Int {
        switch kind {
        case .local: 0
        case .personal: 1
        case .team: 2
        }
    }
}

struct TagEditorAssignmentState: Equatable {
    var searchText = ""
    private(set) var pendingChanges = FileTagChangeSet()

    func effectiveSelectionState(for tag: FileTag, baseState: TagSelectionState) -> TagSelectionState {
        if pendingChanges.additions.contains(tag) { return .checked }
        if pendingChanges.removals.contains(tag) { return .empty }
        return baseState
    }

    mutating func toggle(_ tag: FileTag, baseState: TagSelectionState) {
        let next: TagSelectionState = effectiveSelectionState(for: tag, baseState: baseState) == .checked
            ? .empty
            : .checked
        set(tag, to: next, baseState: baseState)
    }

    mutating func selectCreatedTag(_ tag: FileTag) {
        set(tag, to: .checked, baseState: .empty)
    }

    mutating func clear() {
        pendingChanges = .init()
    }

    mutating func reconcileCatalogDeletion(of tag: FileTag) {
        pendingChanges = .init(
            add: pendingChanges.additions.filter { $0 != tag },
            remove: pendingChanges.removals.filter { $0 != tag }
        )
    }

    private mutating func set(_ tag: FileTag, to desiredState: TagSelectionState, baseState: TagSelectionState) {
        var additions = pendingChanges.additions.filter { $0 != tag }
        var removals = pendingChanges.removals.filter { $0 != tag }
        switch (baseState, desiredState) {
        case (.checked, .checked), (.empty, .empty):
            break
        case (.mixed, .checked), (.empty, .checked):
            additions.append(tag)
        case (.checked, .empty), (.mixed, .empty):
            removals.append(tag)
        case (_, .mixed):
            break
        }
        pendingChanges = .init(add: additions, remove: removals)
    }
}

struct TagCatalogManagementState: Equatable {
    enum Mode: Equatable {
        case create
        case rename(FileTag)
    }

    var scopeID: String
    var mode: Mode = .create
    var name = ""

    init(scopeID: String) {
        self.scopeID = scopeID
    }

    var mutation: FileTagCatalogMutation? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        switch mode {
        case .create:
            return .createTag(name: trimmedName, groupID: nil)
        case .rename(let tag):
            return .renameTag(id: tag.id, name: trimmedName)
        }
    }

    mutating func beginCreate(in scope: FileTagScope) {
        scopeID = scope.id
        mode = .create
        name = ""
    }

    mutating func beginRename(tag: FileTag) {
        scopeID = tag.scopeID
        mode = .rename(tag)
        name = tag.name
    }
}

@MainActor
final class TagEditorContext: ObservableObject, Identifiable {
    let id = UUID()
    let commonEditableScope: FileTagScope

    @Published private(set) var selectedItemIDs: Set<String>
    @Published private(set) var selectedItems: [FileItem]
    @Published private(set) var catalog: FileTagCatalog
    @Published private(set) var tagSelectionStates: [FileTag: TagSelectionState]
    @Published private(set) var operationState: TagEditorOperationState = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var isReadOnly = false
    @Published private(set) var isActive = true
    @Published private(set) var applyResult: TagApplyResult?

    init(selectedItems: [FileItem], commonEditableScope: FileTagScope) {
        self.commonEditableScope = commonEditableScope
        self.selectedItemIDs = Set(selectedItems.map(\.id))
        self.selectedItems = selectedItems
        self.catalog = .init(
            scopes: [commonEditableScope],
            tags: Self.visibleTags(in: selectedItems, scopeID: commonEditableScope.id)
        )
        self.tagSelectionStates = [:]
        updateTagSelectionStates()
    }

    var canAssociateTags: Bool {
        isActive
            && operationState == .idle
            && !selectedItems.isEmpty
            && commonEditableScope.capabilities.canAssociate
            && !isReadOnly
    }

    var canManageCatalog: Bool {
        isActive
            && operationState == .idle
            && !selectedItems.isEmpty
            && !isReadOnly
            && TagEditorPresentation.manageableScopes(in: catalog).contains { $0.id == commonEditableScope.id }
    }

    var canRetryCatalog: Bool {
        isActive && isReadOnly && errorMessage != nil
    }

    func selectionState(for tag: FileTag) -> TagSelectionState {
        tagSelectionStates[tag] ?? .empty
    }

    func begin(_ state: TagEditorOperationState) {
        operationState = state
        errorMessage = nil
    }

    func replaceCatalog(_ catalog: FileTagCatalog) {
        self.catalog = Self.merging(catalog, with: selectedItems, commonEditableScope: commonEditableScope)
        operationState = .idle
        errorMessage = nil
        isReadOnly = false
        updateTagSelectionStates()
    }

    func catalogUnavailable(message: String) {
        operationState = .idle
        errorMessage = message
        isReadOnly = true
        updateTagSelectionStates()
    }

    func completeApply(_ result: TagApplyResult?, errorMessage: String?) {
        applyResult = result
        operationState = .idle
        self.errorMessage = errorMessage
    }

    func completeCatalogMutation(errorMessage: String?) {
        operationState = .idle
        self.errorMessage = errorMessage
    }

    func deactivate() {
        isActive = false
        isReadOnly = true
        operationState = .idle
        errorMessage = nil
    }

    func refreshSelectedItems(from items: [FileItem]) {
        selectedItemIDs.formIntersection(Set(items.map(\.id)))
        selectedItems = items.filter { selectedItemIDs.contains($0.id) }
        catalog = Self.merging(catalog, with: selectedItems, commonEditableScope: commonEditableScope)
        updateTagSelectionStates()
    }

    private func updateTagSelectionStates() {
        let scopedTags = Self.visibleTags(in: selectedItems, scopeID: commonEditableScope.id)
        let availableTags = Self.uniqueTags(catalog.tags + scopedTags)
        tagSelectionStates = Dictionary(uniqueKeysWithValues: availableTags.map { tag in
            let count = selectedItems.reduce(into: 0) { total, item in
                if item.tags.contains(tag) {
                    total += 1
                }
            }
            let state: TagSelectionState
            switch count {
            case 0:
                state = .empty
            case let selectedCount where selectedCount == selectedItems.count:
                state = .checked
            default:
                state = .mixed
            }
            return (tag, state)
        })
    }

    private static func merging(
        _ catalog: FileTagCatalog,
        with selectedItems: [FileItem],
        commonEditableScope: FileTagScope
    ) -> FileTagCatalog {
        let scopes = uniqueScopes([commonEditableScope] + catalog.scopes)
        let tags = uniqueTags(catalog.tags + visibleTags(in: selectedItems, scopeID: commonEditableScope.id))
        return .init(scopes: scopes, groups: catalog.groups, tags: tags, providerState: catalog.providerState)
    }

    private static func visibleTags(in items: [FileItem], scopeID: String) -> [FileTag] {
        uniqueTags(items.flatMap(\.tags).filter { $0.scopeID == scopeID })
    }

    private static func uniqueTags(_ tags: [FileTag]) -> [FileTag] {
        var seen = Set<FileTag>()
        return tags.filter { seen.insert($0).inserted }
    }

    private static func uniqueScopes(_ scopes: [FileTagScope]) -> [FileTagScope] {
        var seen = Set<String>()
        return scopes.filter { seen.insert($0.id).inserted }
    }
}
