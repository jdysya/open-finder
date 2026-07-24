import Foundation
import OpenFinderCore

extension AppModel {
    func dismissPresentedPluginResult() {
        presentedPluginResult = nil
    }

    func dismissPluginResult() {
        dismissPresentedPluginResult()
    }

    func presentPluginResult(_ projection: PluginResultProjection) {
        presentedPluginResult = projection
    }

    func renderer(for projection: PluginResultProjection) -> PluginRendererDescriptor {
        services.renderer(for: projection)
    }

    func resolvePresentedPluginResultArtifact(_ id: UUID) async -> URL? {
        await services.artifactURL(for: id)
    }

    func performPresentedPluginResultAction(
        _ action: PresentedPluginResultAction
    ) async -> PresentedPluginResultActionOutcome {
        await services.perform(action)
    }

    func presentedPluginResultActionBridge() -> PresentedPluginResultActionBridge {
        .init(action: { [weak self] action in
            guard let self else {
                return .init(message: "", managedTagsByMedia: [:])
            }
            return await self.performPresentedPluginResultAction(action)
        })
    }

    func runPlugin(
        _ plugin: LoadedPlugin,
        action: PluginActionManifest,
        items: [FileItem],
        pane: BrowserPaneModel
    ) {
        Task {
            do {
                if case .http = plugin.manifest.execution {
                    let connection = await checkPluginConnection(plugin)
                    guard connection.canSubmit else {
                        statusMessage = connection.guidance
                        return
                    }
                }
                let queuedID = try await services.submitPlugin(
                    plugin,
                    action: action,
                    items: items,
                    pane: pane,
                    configuration: configuration
                )
                statusMessage = "Queued plugin task \(queuedID.uuidString.prefix(8))"
                await observeTask(queuedID)
                if let projection = await services.takePluginResult(for: queuedID) {
                    presentPluginResult(projection)
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func requireDurableHandlerReadiness() async throws {
        do {
            try await services.requireDurableReadiness()
            durableHandlerReadiness = .ready
        } catch {
            durableHandlerReadiness = .unavailable(error.localizedDescription)
            throw error
        }
    }
}
