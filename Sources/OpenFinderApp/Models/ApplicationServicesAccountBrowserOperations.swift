import Foundation
import OpenFinderCore

@MainActor
extension ApplicationServices {
    var remoteConnectors: [RemoteConnector] {
        accountService.connectors
    }

    func remoteAccounts() -> [RemoteAccount] {
        accountService.accounts()
    }

    func addRemoteAccount(
        connectorID: RemoteConnectorID,
        name: String,
        endpoint: String,
        username: String,
        password: String,
        allowInsecureHTTP: Bool
    ) throws -> RemoteAccountMutation {
        try accountService.addAccount(
            connectorID: connectorID,
            name: name,
            endpoint: endpoint,
            username: username,
            password: password,
            allowInsecureHTTP: allowInsecureHTTP
        )
    }

    func removeRemoteAccount(_ account: RemoteAccount) async throws -> RemoteAccountMutation {
        try await accountService.removeAccount(account)
    }

    func remoteRoot(for account: RemoteAccount) throws -> Location {
        try accountService.rootLocation(for: account)
    }

    func submitTransfer(
        _ items: [FileItem],
        source: Location,
        destination: Location,
        move: Bool,
        overwriteExisting: Bool,
        title: String
    ) async throws -> UUID {
        try await browserService.submitTransfer(
            items,
            source: source,
            destination: destination,
            move: move,
            overwriteExisting: overwriteExisting,
            title: title
        )
    }

    func normalizedLocation(_ location: Location) throws -> Location {
        try browserService.normalizedLocation(location)
    }
}
