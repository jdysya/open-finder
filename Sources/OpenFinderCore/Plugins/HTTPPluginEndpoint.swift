import Foundation

public struct HTTPPluginEndpoint: Equatable, Sendable {
    public let baseURL: URL

    public init(_ configuredValue: String) throws {
        guard configuredValue == configuredValue.trimmingCharacters(in: .whitespacesAndNewlines),
              configuredValue.hasPrefix("http://"),
              !configuredValue.contains("?"), !configuredValue.contains("#"),
              !configuredValue.contains("\\"), !configuredValue.contains("%")
        else { throw HTTPPluginError.invalidEndpoint }

        let raw = String(configuredValue.dropFirst("http://".count))
        let pieces = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 1 || (pieces.count == 2 && pieces[1].isEmpty) else {
            throw HTTPPluginError.invalidEndpoint
        }
        let authority = String(pieces[0])
        let portString: String
        if authority.hasPrefix("[") {
            guard authority.hasPrefix("[::1]:") else { throw HTTPPluginError.invalidEndpoint }
            portString = String(authority.dropFirst("[::1]:".count))
        } else {
            guard authority.hasPrefix("127.0.0.1:") else { throw HTTPPluginError.invalidEndpoint }
            portString = String(authority.dropFirst("127.0.0.1:".count))
        }
        guard !portString.isEmpty, portString.allSatisfy(\.isNumber),
              let port = Int(portString), (1 ... 65_535).contains(port)
        else { throw HTTPPluginError.invalidEndpoint }

        let canonicalHost = authority.hasPrefix("[") ? "[::1]" : "127.0.0.1"
        guard let url = URL(string: "http://\(canonicalHost):\(port)/openfinder/plugin/v1") else {
            throw HTTPPluginError.invalidEndpoint
        }
        baseURL = url
    }

    public func route(_ components: String...) -> URL {
        components.reduce(baseURL) { $0.appendingPathComponent($1) }
    }

    static func prepare(
        request: PluginRunRequest,
        credentialResolver: @Sendable (String) throws -> String?
    ) throws -> HTTPPluginPreparedRequest {
        guard case .http(let version, let endpointKey, let tokenKey) = request.manifest.execution,
              version == 1 else { throw HTTPPluginError.executionMismatch }
        guard let configuredURL = request.input.config[endpointKey], !configuredURL.isEmpty else {
            throw HTTPPluginError.missingConfiguration(endpointKey)
        }
        guard let reference = request.input.secrets[tokenKey]?.env, !reference.isEmpty else {
            throw HTTPPluginError.missingCredential(tokenKey)
        }
        guard let token = try credentialResolver(reference), !token.isEmpty else {
            throw HTTPPluginError.missingCredential(tokenKey)
        }
        guard token.utf8.allSatisfy({ (0x21 ... 0x7e).contains($0) }) else {
            throw HTTPPluginError.invalidCredential(tokenKey)
        }
        var secrets = request.input.secrets
        secrets.removeValue(forKey: tokenKey)
        let input = PluginInput(
            schemaVersion: request.input.schemaVersion, taskID: request.input.taskID,
            actionID: request.input.actionID, app: request.input.app, context: request.input.context,
            files: request.input.files, config: request.input.config, secrets: secrets,
            tempDirectory: request.input.tempDirectory, outputDirectory: request.input.outputDirectory
        )
        return .init(endpoint: try HTTPPluginEndpoint(configuredURL), bearerToken: token, input: input)
    }
}
