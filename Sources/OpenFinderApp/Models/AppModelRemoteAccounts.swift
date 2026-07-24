import Foundation
import OpenFinderCore

extension AppModel {
    var remoteConnectors: [RemoteConnector] { services.remoteConnectors }

    func addWebDAVAccount(
        name: String,
        baseURL: String,
        username: String,
        password: String,
        allowInsecureHTTP: Bool
    ) {
        addRemoteAccount(
            connectorID: .webDAV,
            name: name,
            endpoint: baseURL,
            username: username,
            password: password,
            allowInsecureHTTP: allowInsecureHTTP
        )
    }

    func addRemoteAccount(
        connectorID: RemoteConnectorID,
        name: String,
        endpoint: String,
        username: String,
        password: String,
        allowInsecureHTTP: Bool
    ) {
        do {
            let mutation = try services.addRemoteAccount(
                connectorID: connectorID,
                name: name,
                endpoint: endpoint,
                username: username,
                password: password,
                allowInsecureHTTP: allowInsecureHTTP
            )
            remoteAccounts = mutation.accounts
            statusMessage = mutation.statusMessage
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeWebDAVAccount(_ account: RemoteAccount) {
        removeRemoteAccount(account)
    }

    func removeRemoteAccount(_ account: RemoteAccount) {
        Task {
            do {
                let mutation = try await services.removeRemoteAccount(account)
                remoteAccounts = mutation.accounts
                statusMessage = mutation.statusMessage
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func openWebDAVAccountInActivePane(_ account: RemoteAccount) {
        openRemoteAccountInActivePane(account)
    }

    func openRemoteAccountInActivePane(_ account: RemoteAccount) {
        Task {
            do {
                await activeBrowser.navigate(to: try services.remoteRoot(for: account))
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}
