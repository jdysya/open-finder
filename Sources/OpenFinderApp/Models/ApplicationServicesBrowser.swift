import Foundation
import OpenFinderCore

@MainActor
extension ApplicationServices {
    func makeBrowserPanes() -> (left: BrowserPaneModel, right: BrowserPaneModel) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let providerRegistry = accountService.providerRegistry
        let resolver: @Sendable (RemoteLocation) async throws -> any RemoteProvider = { location in
            try await providerRegistry.resolve(
                accountID: location.accountID.uuidString,
                revision: location.connectorID.rawValue
            )
        }
        return (
            BrowserPaneModel(
                id: .left,
                location: .local(path: home.path),
                remoteProviderResolver: resolver,
                fileSourceRegistry: fileSources,
                fileBrowserService: browserService
            ),
            BrowserPaneModel(
                id: .right,
                location: .local(
                    path: home.appendingPathComponent("Downloads", isDirectory: true).path
                ),
                remoteProviderResolver: resolver,
                fileSourceRegistry: fileSources,
                fileBrowserService: browserService
            )
        )
    }

    nonisolated static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("OpenFinder", isDirectory: true)
    }
}
