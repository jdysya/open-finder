import Foundation
import OpenFinderCore

extension BrowserPaneModel {
    func tagProvider(for location: Location) async throws -> (any TagProvider)? {
        let source = try await resolvedFileSource(for: location)
        switch source.adapter {
        case .local(let adapter):
            return adapter.provider
        case .remote(let adapter):
            return adapter.provider as? any TagProvider
        }
    }

    func beginTagEditorRequest() -> UInt64 {
        invalidateTagEditorSession()
        return tagEditorGeneration
    }

    func invalidateTagEditorSession() {
        tagEditorGeneration &+= 1
        tagEditorSession?.context.deactivate()
        tagEditorSession = nil
    }

    func isCurrentTagEditorRequest(
        _ generation: UInt64,
        location: Location
    ) -> Bool {
        tagEditorGeneration == generation && self.location == location
    }

    func isCurrentTagEditorSession(_ session: TagEditorSession) -> Bool {
        guard tagEditorGeneration == session.generation,
              location == session.location,
              let currentSession = tagEditorSession
        else {
            return false
        }
        return currentSession.generation == session.generation
            && currentSession.context === session.context
    }

    func tagApplyErrorMessage(for failures: [TagApplyFailure]) -> String {
        failures.map { failure in
            "\(failure.itemID): \(failure.message)"
        }
        .joined(separator: "\n")
    }
}
