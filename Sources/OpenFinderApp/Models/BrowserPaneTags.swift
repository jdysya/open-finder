import Foundation
import OpenFinderCore

extension BrowserPaneModel {
    func prepareTagEditor() async -> TagEditorContext? {
        let selected = selectedItems
        do {
            try requireCapability(.editTags, items: selected)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        guard let scope = FileTableTagActionAvailability.commonEditableScope(for: selected) else {
            return nil
        }

        let requestLocation = location
        let generation = beginTagEditorRequest()
        guard let tagProvider = try? await tagProvider(for: requestLocation),
              isCurrentTagEditorRequest(generation, location: requestLocation)
        else {
            return nil
        }

        let context = TagEditorContext(
            selectedItems: selected,
            commonEditableScope: scope
        )
        let session = TagEditorSession(
            generation: generation,
            location: requestLocation,
            context: context,
            provider: tagProvider
        )
        tagEditorSession = session
        await reloadTagCatalog(for: session)
        return isCurrentTagEditorSession(session) ? context : nil
    }

    func reloadTagCatalog() async {
        guard let session = tagEditorSession,
              session.context.operationState == .idle
        else {
            return
        }
        await reloadTagCatalog(for: session)
    }

    private func reloadTagCatalog(for session: TagEditorSession) async {
        guard isCurrentTagEditorSession(session),
              session.context.operationState == .idle
        else {
            return
        }
        session.context.begin(.loadingCatalog)
        do {
            let catalog = try await session.provider.tagCatalog(for: session.location)
            guard isCurrentTagEditorSession(session) else { return }
            session.context.replaceCatalog(catalog)
        } catch {
            guard isCurrentTagEditorSession(session) else { return }
            session.context.catalogUnavailable(message: error.localizedDescription)
        }
    }

    func applyTagChanges(_ changes: FileTagChangeSet) async {
        guard let session = tagEditorSession,
              isCurrentTagEditorSession(session),
              session.context.operationState == .idle,
              session.context.canAssociateTags,
              !changes.isEmpty
        else {
            return
        }

        do {
            try requireCapability(.editTags, items: session.context.selectedItems)
        } catch {
            session.context.completeApply(nil, errorMessage: error.localizedDescription)
            errorMessage = error.localizedDescription
            return
        }
        session.context.begin(.applyingChanges)
        let result: TagApplyResult?
        let operationError: String?
        do {
            let applied = try await session.provider.apply(
                changes,
                to: session.context.selectedItems
            )
            result = applied
            operationError = applied.failures.isEmpty
                ? nil
                : tagApplyErrorMessage(for: applied.failures)
        } catch {
            result = nil
            operationError = error.localizedDescription
        }

        guard isCurrentTagEditorSession(session) else { return }
        await refresh(preservingTagEditorSession: session)
        guard isCurrentTagEditorSession(session) else { return }
        session.context.refreshSelectedItems(from: items)
        session.context.completeApply(result, errorMessage: operationError)
        if let operationError {
            errorMessage = operationError
        }
    }

    @discardableResult
    func mutateTagCatalog(_ mutation: FileTagCatalogMutation) async -> Bool {
        guard let session = tagEditorSession,
              isCurrentTagEditorSession(session),
              session.context.operationState == .idle,
              session.context.canManageCatalog
        else {
            return false
        }

        do {
            try requireCapability(.editTags, items: session.context.selectedItems)
        } catch {
            session.context.completeCatalogMutation(errorMessage: error.localizedDescription)
            errorMessage = error.localizedDescription
            return false
        }
        session.context.begin(.mutatingCatalog)
        let catalog: FileTagCatalog?
        let operationError: String?
        do {
            catalog = try await session.provider.mutate(
                mutation,
                in: session.context.commonEditableScope
            )
            operationError = nil
        } catch {
            catalog = nil
            operationError = error.localizedDescription
        }

        guard isCurrentTagEditorSession(session) else { return false }
        await refresh(preservingTagEditorSession: session)
        guard isCurrentTagEditorSession(session) else { return false }
        session.context.refreshSelectedItems(from: items)
        if let catalog {
            session.context.replaceCatalog(catalog)
        }
        session.context.completeCatalogMutation(errorMessage: operationError)
        if let operationError {
            errorMessage = operationError
        }
        return catalog != nil
    }
}
