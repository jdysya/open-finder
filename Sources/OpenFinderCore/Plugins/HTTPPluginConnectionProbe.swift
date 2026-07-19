import Foundation

public struct HTTPPluginConnectionProbe: PluginConnectionChecking {
    private let transport: any HTTPPluginTransportProtocol
    private let credentialResolver: @Sendable (String) throws -> String?

    public init(credentialStore: any KeychainStore) {
        self.init(
            transport: URLSessionHTTPPluginTransport(),
            credentialResolver: { try credentialStore.secret(for: $0) }
        )
    }

    public init(credentialResolver: PluginCredentialResolver) {
        self.init(
            transport: URLSessionHTTPPluginTransport(),
            credentialResolver: { try credentialResolver.secret(for: $0) }
        )
    }

    init(
        transport: any HTTPPluginTransportProtocol,
        credentialResolver: @escaping @Sendable (String) throws -> String?
    ) {
        self.transport = transport
        self.credentialResolver = credentialResolver
    }

    init(
        transport: any HTTPPluginTransportProtocol,
        credentialResolver: PluginCredentialResolver
    ) {
        self.init(
            transport: transport,
            credentialResolver: { try credentialResolver.secret(for: $0) }
        )
    }

    public func check(
        manifest: PluginManifest,
        values: [String: String],
        secretReferences: [String: String]
    ) async -> PluginConnectionStatus {
        guard case .http(let version, let endpointKey, let tokenKey) = manifest.execution else {
            return unavailable(.invalidResponse, "This plugin does not use a local HTTP service.")
        }
        let credentialLocation = credentialLocation(for: manifest.permissions.storage(for: tokenKey))
        guard version == 1 else {
            return unavailable(.incompatibleProtocol, "Update OpenFinder or the plugin to use HTTP protocol version 1.")
        }
        guard let configuredEndpoint = values[endpointKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !configuredEndpoint.isEmpty else {
            return unavailable(.missingEndpoint, "Configure the local server endpoint, then test the connection again.")
        }
        let endpoint: HTTPPluginEndpoint
        do { endpoint = try HTTPPluginEndpoint(configuredEndpoint) }
        catch { return unavailable(.invalidEndpoint, "Use a loopback URL such as http://127.0.0.1:8765.") }

        guard let reference = secretReferences[tokenKey], !reference.isEmpty else {
            return unavailable(.missingToken, "Save the server token in \(credentialLocation), then test the connection again.")
        }
        let token: String
        do {
            guard let resolved = try credentialResolver(reference), !resolved.isEmpty else {
                return unavailable(.missingToken, "Save the server token in \(credentialLocation), then test the connection again.")
            }
            token = resolved
        } catch {
            return unavailable(.missingToken, "OpenFinder could not read the server token from \(credentialLocation).")
        }
        guard token.utf8.allSatisfy({ (0x21 ... 0x7e).contains($0) }) else {
            return unavailable(.authenticationFailed, "Replace the invalid server token and try again.")
        }

        do {
            let request = HTTPPluginRequestFactory.make(endpoint: endpoint, route: ["health"], token: token)
            let response = try await transport.data(for: request)
            if response.statusCode == 401 || response.statusCode == 403 {
                return unavailable(.authenticationFailed, "The server rejected the token. Save the matching token in \(credentialLocation) and retry.")
            }
            let data = try HTTPPluginResponseValidator.data(response, accepted: [200], token: token)
            if try protocolVersion(in: data) != 1 {
                return unavailable(.incompatibleProtocol, "The server uses an incompatible protocol. Update the server or OpenFinder.")
            }
            let health = try HTTPPluginWire.health(data)
            if let pluginID = health.pluginID {
                guard pluginID == manifest.id else {
                    return unavailable(.incompatiblePlugin, "The configured endpoint belongs to a different plugin.")
                }
            } else {
                let request = HTTPPluginRequestFactory.make(
                    endpoint: endpoint, route: ["capabilities"], token: token
                )
                let response = try await transport.data(for: request)
                let data = try HTTPPluginResponseValidator.data(response, accepted: [200], token: token)
                if try protocolVersion(in: data) != 1 {
                    return unavailable(.incompatibleProtocol, "The server uses an incompatible protocol. Update the server or OpenFinder.")
                }
                let capabilities = try HTTPPluginWire.capabilities(data)
                guard capabilities.pluginID == manifest.id else {
                    return unavailable(.incompatiblePlugin, "The configured endpoint belongs to a different plugin.")
                }
            }
            return status(from: health, token: token)
        } catch let error as HTTPPluginError {
            return mapped(error, token: token, credentialLocation: credentialLocation)
        } catch {
            return unavailable(.serverUnavailable, "Start the local plugin server, then test the connection again.")
        }
    }

    private func status(from health: HTTPPluginHealth, token: String) -> PluginConnectionStatus {
        let checks = (health.checks ?? []).map {
            PluginConnectionCheck(
                id: HTTPPluginRedactor.message($0.id, token: token),
                status: $0.status,
                message: HTTPPluginRedactor.message($0.message, token: token),
                remediation: $0.remediation.map { HTTPPluginRedactor.message($0, token: token) }
            )
        }
        let runtime = health.runtime.map {
            PluginConnectionRuntime(
                name: HTTPPluginRedactor.message($0.name, token: token),
                version: HTTPPluginRedactor.message($0.version, token: token)
            )
        }
        let pluginVersion = health.pluginVersion.map { HTTPPluginRedactor.message($0, token: token) }
        switch health.status {
        case "ready":
            return .init(state: .ready, guidance: "The local plugin service is ready.",
                         protocolVersion: health.protocolVersion, pluginID: health.pluginID,
                         pluginVersion: pluginVersion, runtime: runtime, checks: checks)
        case "degraded":
            return .init(state: .degraded, issue: .environmentUnavailable,
                         guidance: "Resolve the environment checks before starting analysis.",
                         protocolVersion: health.protocolVersion, pluginID: health.pluginID,
                         pluginVersion: pluginVersion, runtime: runtime, checks: checks)
        default:
            return .init(state: .unavailable, issue: .environmentUnavailable,
                         guidance: "Resolve the reported server environment checks, then retry.",
                         protocolVersion: health.protocolVersion, pluginID: health.pluginID,
                         pluginVersion: pluginVersion, runtime: runtime, checks: checks)
        }
    }

    private func mapped(
        _ error: HTTPPluginError,
        token: String,
        credentialLocation: String
    ) -> PluginConnectionStatus {
        switch error {
        case .server(let status, _, _, _) where status == 401 || status == 403:
            unavailable(.authenticationFailed, "The server rejected the token. Save the matching token in \(credentialLocation) and retry.")
        case .transport:
            unavailable(.serverUnavailable, "Start the local plugin server, then test the connection again.")
        case .invalidResponse:
            unavailable(.invalidResponse, "The server response is incompatible. Update the server and retry.")
        default:
            unavailable(.serverUnavailable, HTTPPluginRedactor.message(error.localizedDescription, token: token))
        }
    }

    private func credentialLocation(for storage: PluginSecretStorage?) -> String {
        switch storage {
        case .localConfiguration: "the secured local config"
        case .keychain: "Keychain"
        case nil: "the configured credential store"
        }
    }

    private func protocolVersion(in data: Data) throws -> Int? {
        (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["protocolVersion"] as? Int
    }

    private func unavailable(_ issue: PluginConnectionIssue, _ guidance: String) -> PluginConnectionStatus {
        .init(state: .unavailable, issue: issue, guidance: guidance)
    }
}
