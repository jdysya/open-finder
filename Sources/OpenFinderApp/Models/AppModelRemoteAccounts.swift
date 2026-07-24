import Foundation
import OpenFinderCore

extension AppModel {
    var remoteConnectors: [RemoteConnector] { remoteConnectorRegistry.connectors }

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
            guard let connector = remoteConnectorRegistry.connector(id: connectorID) else {
                throw OpenFinderError.operationFailed(
                    "Unknown remote connector: \(connectorID.rawValue)"
                )
            }
            let accountID = UUID()
            let secretRef = "remote.\(connector.id.rawValue).\(accountID.uuidString).password"
            let account = try connector.makeAccount(
                id: accountID,
                name: name,
                endpoint: endpoint,
                username: username,
                secretKeychainRef: password.isEmpty ? nil : secretRef,
                allowInsecureHTTP: allowInsecureHTTP
            )
            if !password.isEmpty {
                try pluginManagementService.setStoredSecret(password, for: secretRef)
            }
            remoteDirectory.save(account)
            remoteAccounts = remoteDirectory.all()
            statusMessage = "Added \(connector.displayName) account \(account.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeWebDAVAccount(_ account: RemoteAccount) {
        removeRemoteAccount(account)
    }

    func removeRemoteAccount(_ account: RemoteAccount) {
        Task {
            await remoteProviderRegistry.invalidate(accountID: account.id.uuidString)
            do {
                if let ref = account.secretKeychainRef {
                    try pluginManagementService.deleteStoredSecret(for: ref)
                }
                remoteDirectory.remove(id: account.id)
                remoteAccounts = remoteDirectory.all()
                let connectorName = remoteConnectorRegistry.connector(for: account)?.displayName
                    ?? "Remote"
                statusMessage = "Removed \(connectorName) account \(account.name)"
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
            guard let connector = remoteConnectorRegistry.connector(for: account) else {
                statusMessage = "No connector is available for \(account.name)"
                return
            }
            let root = connector.providerKind == .kodbox
                ? RemotePath(identifier: KodboxProvider.syntheticRootIdentifier, displayPath: "/")
                : RemotePath(identifier: "/", displayPath: "/")
            await activeBrowser.navigate(to: .remote(.init(
                accountID: account.id,
                connectorID: connector.id,
                path: root
            )))
        }
    }
}
