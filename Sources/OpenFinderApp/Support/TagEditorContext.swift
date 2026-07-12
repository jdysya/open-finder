import Combine
import Foundation
import OpenFinderCore

enum TagSelectionState: Equatable {
    case empty
    case mixed
    case checked
}

enum TagEditorOperationState: Equatable {
    case idle
    case loadingCatalog
    case applyingChanges
    case mutatingCatalog
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
        isActive && !selectedItems.isEmpty && commonEditableScope.capabilities.canAssociate && !isReadOnly
    }

    var canManageCatalog: Bool {
        let capabilities = commonEditableScope.capabilities
        return isActive && !selectedItems.isEmpty && !isReadOnly && (
            capabilities.canCreate
                || capabilities.canRename
                || capabilities.canUpdateStyle
                || capabilities.canDelete
                || capabilities.canOrganizeGroups
        )
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
