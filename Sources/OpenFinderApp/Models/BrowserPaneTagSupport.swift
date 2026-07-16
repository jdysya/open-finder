import Foundation
import OpenFinderCore

extension BrowserPaneModel {
    func tagProvider(for location: Location) async throws -> (any TagProvider)? {
        switch location {
        case .local:
            return provider
        case .webDAV, .remote:
            let remoteLocation = try remoteLocation(for: location)
            let remote = try await remoteProvider(for: remoteLocation)
            return remote as? any TagProvider
        case .rclone:
            return nil
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
