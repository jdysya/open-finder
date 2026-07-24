import Foundation
import OpenFinderCore

struct RemoteAccountMutation {
    let accounts: [RemoteAccount]
    let statusMessage: String
}

@MainActor
final class RemoteAccountService {
    let directory: RemoteAccountDirectory
    let connectorRegistry: RemoteConnectorRegistry
    let providerRegistry: RemoteProviderRegistry
    private let keychainStore: any KeychainStore

    init(
        directory: RemoteAccountDirectory,
        connectorRegistry: RemoteConnectorRegistry,
        providerRegistry: RemoteProviderRegistry,
        keychainStore: any KeychainStore
    ) {
        self.directory = directory
        self.connectorRegistry = connectorRegistry
        self.providerRegistry = providerRegistry
        self.keychainStore = keychainStore
    }

    var connectors: [RemoteConnector] { connectorRegistry.connectors }

    func accounts() -> [RemoteAccount] {
        directory.all()
    }

    func addAccount(
        connectorID: RemoteConnectorID,
        name: String,
        endpoint: String,
        username: String,
        password: String,
        allowInsecureHTTP: Bool
    ) throws -> RemoteAccountMutation {
        guard let connector = connectorRegistry.connector(id: connectorID) else {
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
            try keychainStore.setSecret(password, for: secretRef)
        }
        directory.save(account)
        return .init(
            accounts: directory.all(),
            statusMessage: "Added \(connector.displayName) account \(account.name)"
        )
    }

    func removeAccount(_ account: RemoteAccount) async throws -> RemoteAccountMutation {
        await providerRegistry.invalidate(accountID: account.id.uuidString)
        if let ref = account.secretKeychainRef {
            try keychainStore.deleteSecret(for: ref)
        }
        directory.remove(id: account.id)
        let connectorName = connectorRegistry.connector(for: account)?.displayName ?? "Remote"
        return .init(
            accounts: directory.all(),
            statusMessage: "Removed \(connectorName) account \(account.name)"
        )
    }

    func rootLocation(for account: RemoteAccount) throws -> Location {
        guard let connector = connectorRegistry.connector(for: account) else {
            throw OpenFinderError.operationFailed(
                "No connector is available for \(account.name)"
            )
        }
        let root = connector.providerKind == .kodbox
            ? RemotePath(identifier: KodboxProvider.syntheticRootIdentifier, displayPath: "/")
            : RemotePath(identifier: "/", displayPath: "/")
        return .remote(.init(
            accountID: account.id,
            connectorID: connector.id,
            path: root
        ))
    }
}
