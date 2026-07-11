import Foundation

public actor RemoteProviderRegistry {
    public typealias Factory = @Sendable (_ accountID: String, _ revision: String) async throws -> any RemoteProvider

    public struct UnsupportedProviderError: Error, Equatable, Sendable {
        public let accountID: String
        public let revision: String

        public init(accountID: String, revision: String) {
            self.accountID = accountID
            self.revision = revision
        }
    }

    private let factory: Factory
    private var providers: [String: any RemoteProvider] = [:]

    public init(factory: @escaping Factory) {
        self.factory = factory
    }

    public init(
        connectorRegistry: RemoteConnectorRegistry = .builtIn,
        account: @escaping RemoteConnectorRegistry.AccountResolver,
        credentialStore: KeychainStore,
        webDAVSession: URLSession = .shared,
        kodboxSession: @escaping @Sendable () -> URLSession = { KodboxHTTPClient.ephemeralSession() }
    ) {
        self.init(factory: connectorRegistry.configuredProviderFactory(
            account: account,
            credentialStore: credentialStore,
            webDAVSession: webDAVSession,
            kodboxSession: kodboxSession
        ))
    }

    public func resolve(accountID: String, revision: String) async throws -> any RemoteProvider {
        let key = cacheKey(accountID: accountID, revision: revision)

        if let provider = providers[key] {
            return provider
        }

        let provider: any RemoteProvider
        do {
            provider = try await factory(accountID, revision)
        } catch is UnsupportedProviderError {
            throw UnsupportedProviderError(accountID: accountID, revision: revision)
        }

        providers[key] = provider
        return provider
    }

    public func invalidate(accountID: String, revision: String) {
        providers.removeValue(forKey: cacheKey(accountID: accountID, revision: revision))
    }

    public func invalidate(accountID: String) {
        let prefix = "\(accountID)\u{1F}:"
        providers.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { providers.removeValue(forKey: $0) }
    }

    private func cacheKey(accountID: String, revision: String) -> String {
        "\(accountID)\u{1F}:\(revision)"
    }
}
