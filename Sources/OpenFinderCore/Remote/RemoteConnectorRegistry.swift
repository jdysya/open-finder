import Foundation

public struct RemoteConnectorID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }

    public static let webDAV: Self = "webdav"
    public static let kodbox: Self = "kodbox"
}

public struct RemoteConnector: Identifiable, Hashable, Sendable {
    public let id: RemoteConnectorID
    public let displayName: String
    public let providerKind: RemoteProviderKind
    public let defaultEndpoint: String
    public let endpointHint: String
    public let requiresWebDAVEndpoint: Bool

    public init(
        id: RemoteConnectorID,
        displayName: String,
        providerKind: RemoteProviderKind,
        defaultEndpoint: String,
        endpointHint: String,
        requiresWebDAVEndpoint: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.providerKind = providerKind
        self.defaultEndpoint = defaultEndpoint
        self.endpointHint = endpointHint
        self.requiresWebDAVEndpoint = requiresWebDAVEndpoint
    }

    public func makeAccount(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        username: String,
        secretKeychainRef: String?,
        allowInsecureHTTP: Bool
    ) throws -> RemoteAccount {
        let url = try validatedEndpoint(endpoint, allowInsecureHTTP: allowInsecureHTTP)
        var options = ["connectorID": self.id.rawValue]
        if allowInsecureHTTP {
            options["allowInsecureHTTP"] = "true"
        }
        return RemoteAccount(
            id: id,
            name: resolvedName(name, url: url),
            provider: providerKind,
            baseURL: url,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : username,
            secretKeychainRef: secretKeychainRef,
            options: options
        )
    }

    private func validatedEndpoint(_ endpoint: String, allowInsecureHTTP: Bool) throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host(percentEncoded: false) != nil else {
            throw OpenFinderError.operationFailed("Enter a valid \(displayName) WebDAV endpoint URL.")
        }
        let allowsInsecureHTTP = allowInsecureHTTP && (id != .kodbox || isLoopbackHost(url.host(percentEncoded: false)))
        guard scheme == "https" || (allowsInsecureHTTP && scheme == "http") else {
            if id == .kodbox {
                throw OpenFinderError.operationFailed("Enter an HTTPS \(displayName) server root URL, or explicitly allow insecure HTTP for a loopback development server.")
            }
            throw OpenFinderError.operationFailed("Enter an HTTPS \(displayName) WebDAV endpoint, or explicitly allow insecure HTTP for development.")
        }
        if id == .kodbox {
            let isServerRoot = (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
            guard isServerRoot else {
                throw OpenFinderError.operationFailed("\(displayName) requires the server root URL, not a WebDAV path such as /index.php/dav/.")
            }
        }
        if requiresWebDAVEndpoint {
            let pathSegments = url.path.split(separator: "/", omittingEmptySubsequences: true).map { $0.lowercased() }
            guard pathSegments.contains("dav") else {
                throw OpenFinderError.operationFailed("\(displayName) requires the WebDAV endpoint from Account Center, for example https://host/index.php/dav/.")
            }
        }
        return url
    }

    private func isLoopbackHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "localhost" || normalized == "::1" {
            return true
        }
        let octets = normalized.split(separator: ".")
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { octet in
            guard let value = Int(octet) else { return false }
            return (0...255).contains(value)
        }
    }

    private func resolvedName(_ name: String, url: URL) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if id == .webDAV, let host = url.host(percentEncoded: false), !host.isEmpty {
            return host
        }
        return displayName
    }
}

public struct RemoteConnectorRegistry: Sendable {
    public typealias AccountResolver = @Sendable (_ accountID: String) throws -> RemoteAccount?

    private let connectorsByID: [RemoteConnectorID: RemoteConnector]

    public init(connectors: [RemoteConnector]) {
        self.connectorsByID = Dictionary(uniqueKeysWithValues: connectors.map { ($0.id, $0) })
    }

    public var connectors: [RemoteConnector] {
        connectorsByID.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func connector(id: RemoteConnectorID) -> RemoteConnector? {
        connectorsByID[id]
    }

    public func connector(for account: RemoteAccount) -> RemoteConnector? {
        if let rawID = account.options["connectorID"] {
            return connector(id: RemoteConnectorID(rawValue: rawID))
        }
        if account.provider == .webDAV {
            return connector(id: .webDAV)
        }
        return nil
    }

    public func configuredProviderFactory(
        account accountResolver: @escaping AccountResolver,
        credentialStore: KeychainStore,
        webDAVSession: URLSession = .shared,
        kodboxSession: @escaping @Sendable () -> URLSession = { KodboxHTTPClient.ephemeralSession() }
    ) -> RemoteProviderRegistry.Factory {
        { accountID, revision in
            guard let account = try accountResolver(accountID), let connector = connector(for: account) else {
                throw RemoteProviderRegistry.UnsupportedProviderError(accountID: accountID, revision: revision)
            }

            switch connector.providerKind {
            case .webDAV:
                return WebDAVProvider(
                    account: account,
                    credentialStore: credentialStore,
                    session: webDAVSession
                )
            case .kodbox:
                return try makeKodboxProvider(account: account, credentialStore: credentialStore, session: kodboxSession())
            case .sftp, .s3, .rclone:
                throw RemoteProviderRegistry.UnsupportedProviderError(accountID: accountID, revision: revision)
            }
        }
    }

    private func makeKodboxProvider(
        account: RemoteAccount,
        credentialStore: KeychainStore,
        session: URLSession
    ) throws -> KodboxProvider {
        guard let baseURL = account.baseURL, isServerRoot(baseURL) else {
            throw OpenFinderError.operationFailed("Kodbox account has no valid server root URL")
        }
        guard let username = account.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
            throw OpenFinderError.operationFailed("Kodbox account requires a username")
        }
        guard let secretRef = account.secretKeychainRef else {
            throw OpenFinderError.missingSecret("kodbox.\(account.id).password")
        }
        guard let password = try credentialStore.secret(for: secretRef) else {
            throw OpenFinderError.missingSecret(secretRef)
        }
        let apiSession = KodboxAPISession(
            baseURL: baseURL,
            credentials: .init(username: username, password: password),
            session: session
        )
        return KodboxProvider(session: apiSession, accountID: account.id)
    }

    private func isServerRoot(_ url: URL) -> Bool {
        (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
    }

    public static let builtIn = RemoteConnectorRegistry(connectors: [
        RemoteConnector(
            id: .kodbox,
            displayName: "Kodbox",
            providerKind: .kodbox,
            defaultEndpoint: "https://example.com/",
            endpointHint: "Enter the Kodbox server root URL, for example https://host/.",
            requiresWebDAVEndpoint: false
        ),
        RemoteConnector(
            id: .webDAV,
            displayName: "WebDAV",
            providerKind: .webDAV,
            defaultEndpoint: "https://example.com/dav/",
            endpointHint: "Enter the base WebDAV endpoint URL.",
            requiresWebDAVEndpoint: false
        )
    ])
}
