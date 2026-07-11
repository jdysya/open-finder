import Foundation

public struct KodboxBootstrap: Equatable, Sendable {
    public let version: String

    init(version: String) {
        self.version = version
    }
}

public actor KodboxAPISession {
    private let credentials: KodboxCredentials
    private let client: KodboxHTTPClient
    private var accessToken: String?
    private var cachedBootstrap: KodboxBootstrap?
    private var loginTask: Task<KodboxAuthenticatedSession, Error>?

    public init(baseURL: URL, credentials: KodboxCredentials, session: URLSession = KodboxHTTPClient.ephemeralSession()) {
        self.credentials = credentials
        self.client = KodboxHTTPClient(baseURL: baseURL, session: session)
    }

    public func bootstrap() async throws -> KodboxBootstrap {
        try await authenticate().bootstrap
    }

    public func perform<Response: Decodable & Sendable>(
        _ endpoint: KodboxEndpoint,
        form: [String: String],
        response: Response.Type
    ) async throws -> Response {
        let authenticated = try await authenticate()
        do {
            return try await client.perform(endpoint, form: form, accessToken: authenticated.accessToken, credentials: credentials, response: response)
        } catch KodboxAPIError.authenticationFailed {
            let refreshed = try await authenticate(requiringNewTokenAfter: authenticated.accessToken)
            return try await client.perform(endpoint, form: form, accessToken: refreshed.accessToken, credentials: credentials, response: response)
        }
    }

    func upload(localURL: URL, to parentPath: String, named name: String) async throws {
        let authenticated = try await authenticate()
        do {
            try await client.upload(
                localURL: localURL,
                to: parentPath,
                named: name,
                accessToken: authenticated.accessToken,
                credentials: credentials
            )
        } catch KodboxAPIError.authenticationFailed {
            let refreshed = try await authenticate(requiringNewTokenAfter: authenticated.accessToken)
            try await client.upload(
                localURL: localURL,
                to: parentPath,
                named: name,
                accessToken: refreshed.accessToken,
                credentials: credentials
            )
        }
    }

    func download(from remotePath: String) async throws -> URL {
        let authenticated = try await authenticate()
        do {
            return try await client.download(from: remotePath, accessToken: authenticated.accessToken)
        } catch KodboxAPIError.authenticationFailed {
            let refreshed = try await authenticate(requiringNewTokenAfter: authenticated.accessToken)
            return try await client.download(from: remotePath, accessToken: refreshed.accessToken)
        }
    }

    private func authenticate(requiringNewTokenAfter failedToken: String? = nil) async throws -> KodboxAuthenticatedSession {
        if let failedToken, accessToken == failedToken {
            accessToken = nil
            cachedBootstrap = nil
        }
        if let accessToken, let cachedBootstrap {
            return KodboxAuthenticatedSession(accessToken: accessToken, bootstrap: cachedBootstrap)
        }
        if let loginTask {
            return try await loginTask.value
        }

        let client = client
        let credentials = credentials
        let task = Task<KodboxAuthenticatedSession, Error> {
            let accessToken = try await client.login(credentials: credentials)
            let options = try await client.options(accessToken: accessToken, credentials: credentials)
            guard KodboxVersion.isCompatible(options.version) else {
                throw KodboxAPIError.incompatibleServer(version: options.version)
            }
            return KodboxAuthenticatedSession(accessToken: accessToken, bootstrap: KodboxBootstrap(version: options.version))
        }
        loginTask = task
        do {
            let authenticated = try await task.value
            accessToken = authenticated.accessToken
            cachedBootstrap = authenticated.bootstrap
            loginTask = nil
            return authenticated
        } catch {
            loginTask = nil
            throw error
        }
    }
}

private struct KodboxAuthenticatedSession: Sendable {
    let accessToken: String
    let bootstrap: KodboxBootstrap
}

private enum KodboxVersion {
    static func isCompatible(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components[0] == "1", components[1] == "68" else { return false }
        return components.dropFirst(2).allSatisfy { component in
            !component.isEmpty && component.allSatisfy(\.isNumber)
        }
    }
}
