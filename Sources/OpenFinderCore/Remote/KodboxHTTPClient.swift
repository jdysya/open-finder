import Foundation

public enum KodboxEndpoint: String, CaseIterable, Sendable {
    case login = "user/index/loginSubmit"
    case options = "user/view/options"
    case explorerList = "explorer/list/path"
    case explorerPathInfo = "explorer/index/pathInfo"
    case explorerMkdir = "explorer/index/mkdir"
    case explorerMkfile = "explorer/index/mkfile"
    case explorerRename = "explorer/index/pathRename"
    case explorerDelete = "explorer/index/pathDelete"
    case explorerCopy = "explorer/index/pathCopyTo"
    case explorerMove = "explorer/index/pathCuteTo"
    case explorerUpload = "explorer/upload/fileUpload"
    case explorerDownload = "explorer/index/fileOut"
    case tagGet = "explorer/tag/get"
    case tagAdd = "explorer/tag/add"
    case tagEdit = "explorer/tag/edit"
    case tagRemove = "explorer/tag/remove"
    case tagFilesAdd = "explorer/tag/filesAddToTag"
    case tagFilesRemove = "explorer/tag/filesRemoveFromTag"
}

public struct KodboxCredentials: Sendable {
    let username: String
    let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public enum KodboxAPIError: Error, Equatable, LocalizedError, Sendable {
    case authenticationFailed
    case captchaRequired
    case incompatibleServer(version: String)
    case malformedResponse(endpoint: KodboxEndpoint)
    case apiRejected(message: String)
    case network(description: String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "Kodbox authentication failed."
        case .captchaRequired:
            "Kodbox requires CAPTCHA verification."
        case .incompatibleServer(let version):
            "Unsupported Kodbox version \(version). Expected 1.68.x."
        case .malformedResponse(let endpoint):
            "Malformed Kodbox response for \(endpoint.rawValue)."
        case .apiRejected(let message):
            "Kodbox rejected the request: \(message)"
        case .network(let description):
            description
        }
    }
}

public final class KodboxHTTPClient: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = KodboxHTTPClient.ephemeralSession()) {
        self.baseURL = baseURL
        self.session = session
    }

    public static func ephemeralSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration)
    }

    func login(credentials: KodboxCredentials) async throws -> String {
        let data = try await send(
            endpoint: .login,
            form: ["name": credentials.username, "password": credentials.password],
            accessToken: nil
        )
        let envelope = try decodeLoginEnvelope(data, credentials: credentials)
        guard envelope.isSuccess, let token = envelope.accessToken, !token.isEmpty else {
            throw KodboxAPIError.malformedResponse(endpoint: .login)
        }
        return token
    }

    func options(accessToken: String, credentials: KodboxCredentials) async throws -> KodboxOptionsPayload {
        let data = try await send(endpoint: .options, form: [:], accessToken: accessToken)
        let envelope: KodboxEnvelope<KodboxOptionsPayload> = try decodeEnvelope(
            data,
            endpoint: .options,
            credentials: credentials,
            accessToken: accessToken
        )
        guard envelope.isSuccess, let options = envelope.data else {
            throw KodboxAPIError.malformedResponse(endpoint: .options)
        }
        return options
    }

    func perform<Response: Decodable & Sendable>(
        _ endpoint: KodboxEndpoint,
        form: [String: String],
        accessToken: String,
        credentials: KodboxCredentials,
        response: Response.Type
    ) async throws -> Response {
        let data = try await send(endpoint: endpoint, form: form, accessToken: accessToken)
        let envelope: KodboxEnvelope<Response> = try decodeEnvelope(
            data,
            endpoint: endpoint,
            credentials: credentials,
            accessToken: accessToken
        )
        guard envelope.isSuccess, let payload = envelope.data else {
            throw KodboxAPIError.malformedResponse(endpoint: endpoint)
        }
        return payload
    }

    func upload(
        localURL: URL,
        to parentPath: String,
        named name: String,
        accessToken: String,
        credentials: KodboxCredentials
    ) async throws {
        let multipart = try makeMultipartBody(localURL: localURL, parentPath: parentPath, name: name)
        defer { try? FileManager.default.removeItem(at: multipart.url) }

        var request = try transferRequest(endpoint: .explorerUpload, accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        let resourceValues = try multipart.url.resourceValues(forKeys: Set([URLResourceKey.fileSizeKey]))
        let length = resourceValues.fileSize ?? 0
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, fromFile: multipart.url)
        } catch {
            throw KodboxAPIError.network(description: "Kodbox upload failed at \(KodboxRedactor.url(request.url)): \(KodboxRedactor.message(String(describing: error), secrets: [accessToken]))")
        }
        try validate(response: response, requestURL: request.url)
        let envelope: KodboxEnvelope<KodboxTransferPayload> = try decodeEnvelope(
            data,
            endpoint: .explorerUpload,
            credentials: credentials,
            accessToken: accessToken
        )
        guard envelope.isSuccess else {
            throw KodboxAPIError.malformedResponse(endpoint: .explorerUpload)
        }
    }

    func download(
        from remotePath: String,
        accessToken: String
    ) async throws -> URL {
        let request = try transferRequest(
            endpoint: .explorerDownload,
            accessToken: accessToken,
            query: [
                URLQueryItem(name: "path", value: remotePath),
                URLQueryItem(name: "download", value: "1")
            ]
        )
        let downloadURL: URL
        let response: URLResponse
        do {
            (downloadURL, response) = try await session.download(for: request)
        } catch {
            throw KodboxAPIError.network(description: "Kodbox download failed at \(KodboxRedactor.url(request.url)): \(KodboxRedactor.message(String(describing: error), secrets: [accessToken]))")
        }
        do {
            try validate(response: response, requestURL: request.url)
            return downloadURL
        } catch {
            try? FileManager.default.removeItem(at: downloadURL)
            throw error
        }
    }

    private func send(endpoint: KodboxEndpoint, form: [String: String], accessToken: String?) async throws -> Data {
        let request = try request(endpoint: endpoint, form: form, accessToken: accessToken)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw KodboxAPIError.network(description: "Kodbox network request failed at \(KodboxRedactor.url(request.url)): \(KodboxRedactor.message(String(describing: error), secrets: [accessToken]))")
        }
        guard let http = response as? HTTPURLResponse else {
            throw KodboxAPIError.network(description: "Kodbox returned a non-HTTP response at \(KodboxRedactor.url(request.url)).")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw KodboxAPIError.network(description: "Kodbox returned HTTP \(http.statusCode) at \(KodboxRedactor.url(request.url)).")
        }
        return data
    }

    private func request(endpoint: KodboxEndpoint, form: [String: String], accessToken: String?) throws -> URLRequest {
        var request = try transferRequest(endpoint: endpoint, accessToken: accessToken)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if endpoint == .login {
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        }
        request.httpBody = formBody(form)
        return request
    }

    private func transferRequest(
        endpoint: KodboxEndpoint,
        accessToken: String?,
        query: [URLQueryItem] = []
    ) throws -> URLRequest {
        let apiURL = baseURL.appendingPathComponent("index.php")
        guard var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            throw KodboxAPIError.network(description: "Kodbox endpoint URL is invalid.")
        }
        var queryItems = [URLQueryItem(name: endpoint.rawValue, value: nil)]
        if let accessToken {
            queryItems.append(URLQueryItem(name: "accessToken", value: accessToken))
        }
        queryItems += query
        components.queryItems = queryItems
        guard let url = components.url else {
            throw KodboxAPIError.network(description: "Kodbox endpoint URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("OpenFinder/0.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validate(response: URLResponse, requestURL: URL?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw KodboxAPIError.network(description: "Kodbox returned a non-HTTP response at \(KodboxRedactor.url(requestURL)).")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw KodboxAPIError.network(description: "Kodbox returned HTTP \(http.statusCode) at \(KodboxRedactor.url(requestURL)).")
        }
    }

    private func makeMultipartBody(localURL: URL, parentPath: String, name: String) throws -> KodboxMultipartBody {
        try Task.checkCancellation()
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderKodboxUpload-\(UUID().uuidString)")
        let boundary = "OpenFinder-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw KodboxAPIError.network(description: "Unable to create temporary Kodbox upload body.")
        }

        do {
            let body = try FileHandle(forWritingTo: bodyURL)
            defer { try? body.close() }
            try body.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n\(parentPath)\r\n".utf8))
            try body.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(multipartHeaderValue(name))\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))

            let source = try FileHandle(forReadingFrom: localURL)
            defer { try? source.close() }
            while let data = try source.read(upToCount: 64 * 1_024), !data.isEmpty {
                try Task.checkCancellation()
                try body.write(contentsOf: data)
            }
            try body.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return KodboxMultipartBody(url: bodyURL, boundary: boundary)
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
    }

    private func multipartHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private func formBody(_ form: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = form.keys.sorted().map { key in
            "\(percentEncode(key, allowed: allowed))=\(percentEncode(form[key] ?? "", allowed: allowed))"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private func percentEncode(_ value: String, allowed: CharacterSet) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func decodeEnvelope<Payload: Decodable>(
        _ data: Data,
        endpoint: KodboxEndpoint,
        credentials: KodboxCredentials,
        accessToken: String?
    ) throws -> KodboxEnvelope<Payload> {
        do {
            let envelope = try JSONDecoder().decode(KodboxEnvelope<Payload>.self, from: data)
            if !envelope.isSuccess {
                throw failureError(data: data, endpoint: endpoint, credentials: credentials, accessToken: accessToken)
            }
            return envelope
        } catch let error as KodboxAPIError {
            throw error
        } catch {
            throw KodboxAPIError.malformedResponse(endpoint: endpoint)
        }
    }

    private func decodeLoginEnvelope(_ data: Data, credentials: KodboxCredentials) throws -> KodboxLoginEnvelope {
        do {
            let envelope = try JSONDecoder().decode(KodboxLoginEnvelope.self, from: data)
            if !envelope.isSuccess {
                throw failureError(data: data, endpoint: .login, credentials: credentials, accessToken: nil)
            }
            return envelope
        } catch let error as KodboxAPIError {
            throw error
        } catch {
            throw KodboxAPIError.malformedResponse(endpoint: .login)
        }
    }

    private func failureError(data: Data, endpoint: KodboxEndpoint, credentials: KodboxCredentials, accessToken: String?) -> KodboxAPIError {
        guard let failure = try? JSONDecoder().decode(KodboxFailureEnvelope.self, from: data), !failure.isSuccess else {
            return .malformedResponse(endpoint: endpoint)
        }
        if endpoint == .login, failure.data?.captcha == true {
            return .captchaRequired
        }
        let message = KodboxRedactor.message(failure.message ?? "Unknown Kodbox API error", secrets: [credentials.password, accessToken])
        if KodboxAuthenticationFailure.matches(message) {
            return .authenticationFailed
        }
        return .apiRejected(message: message)
    }
}

private struct KodboxMultipartBody {
    let url: URL
    let boundary: String
}

private struct KodboxTransferPayload: Decodable {
    init(from decoder: Decoder) throws {}
}

struct KodboxOptionsPayload: Decodable, Sendable {
    let version: String

    private enum CodingKeys: String, CodingKey { case version, kod }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let version = try container.decodeIfPresent(String.self, forKey: .version) {
            self.version = version
            return
        }

        let kod = try container.nestedContainer(keyedBy: KodCodingKeys.self, forKey: .kod)
        version = try kod.decode(String.self, forKey: .version)
    }

    private enum KodCodingKeys: String, CodingKey { case version }
}

private struct KodboxLoginPayload: Decodable {
    let accessToken: String
}

private struct KodboxLoginEnvelope: Decodable {
    let isSuccess: Bool
    let accessToken: String?

    private enum CodingKeys: String, CodingKey { case code, data, info }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSuccess = try container.decode(KodboxResultCode.self, forKey: .code).isSuccess
        accessToken = (try? container.decodeIfPresent(String.self, forKey: .info))
            ?? (try? container.decodeIfPresent(KodboxLoginPayload.self, forKey: .data))?.accessToken
    }
}

private struct KodboxEnvelope<Payload: Decodable>: Decodable {
    let isSuccess: Bool
    let data: Payload?

    private enum CodingKeys: String, CodingKey { case code, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(KodboxResultCode.self, forKey: .code)
        isSuccess = code.isSuccess
        if isSuccess {
            data = try container.decode(Payload.self, forKey: .data)
        } else {
            data = nil
        }
    }
}

private struct KodboxFailureEnvelope: Decodable {
    let isSuccess: Bool
    let message: String?
    let data: KodboxFailureData?

    private enum CodingKeys: String, CodingKey { case code, message, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSuccess = try container.decode(KodboxResultCode.self, forKey: .code).isSuccess
        message = try container.decodeIfPresent(String.self, forKey: .message)
        data = try container.decodeIfPresent(KodboxFailureData.self, forKey: .data)
    }
}

private struct KodboxFailureData: Decodable {
    let captcha: Bool?
}

private enum KodboxResultCode: Decodable {
    case bool(Bool)
    case integer(Int)

    var isSuccess: Bool {
        switch self {
        case .bool(let value): value
        case .integer(let value): value != 0
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else {
            throw DecodingError.typeMismatch(KodboxResultCode.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected a boolean or integer Kodbox code."))
        }
    }
}

private enum KodboxAuthenticationFailure {
    static func matches(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return ["authentication", "invalid credential", "login expired", "token expired", "access token"].contains { normalized.contains($0) }
    }
}

private enum KodboxRedactor {
    static func url(_ url: URL?) -> String {
        guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return "<invalid-url>" }
        components.queryItems = components.queryItems?.map { item in
            item.name == "accessToken" ? URLQueryItem(name: item.name, value: "REDACTED") : item
        }
        return components.string ?? "<invalid-url>"
    }

    static func message(_ value: String, secrets: [String?]) -> String {
        secrets.compactMap { $0 }.filter { !$0.isEmpty }.reduce(value) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "REDACTED")
        }
    }
}
