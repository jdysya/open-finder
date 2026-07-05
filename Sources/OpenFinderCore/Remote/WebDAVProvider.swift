import Foundation

public actor WebDAVProvider: RemoteProvider {
    public let account: RemoteAccount
    private let credentialStore: KeychainStore
    private let session: URLSession

    public init(account: RemoteAccount, credentialStore: KeychainStore, session: URLSession = .shared) {
        self.account = account
        self.credentialStore = credentialStore
        self.session = session
    }

    public func list(path: String) async throws -> [RemoteItem] {
        var request = try request(path: path, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, method: "PROPFIND", allowed: [207])
        let basePath = account.baseURL?.path ?? "/"
        let items = try WebDAVMultiStatusParser.parse(data: data).map { Self.item($0, relativeToBasePath: basePath) }
        let normalizedSelf = Self.normalizedRemotePath(path)
        return items.filter { Self.normalizedRemotePath($0.path) != normalizedSelf }
    }

    public func mkdir(path: String) async throws {
        let (data, response) = try await session.data(for: request(path: path, method: "MKCOL"))
        try validate(response, data: data, method: "MKCOL", allowed: [200, 201, 204])
    }

    public func delete(path: String) async throws {
        let (data, response) = try await session.data(for: request(path: path, method: "DELETE"))
        try validate(response, data: data, method: "DELETE", allowed: [200, 202, 204, 207])
    }

    public func move(from: String, to: String) async throws {
        var request = try request(path: from, method: "MOVE")
        request.setValue(try url(for: to).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, method: "MOVE", allowed: [200, 201, 204, 207])
    }

    public func copy(from: String, to: String) async throws {
        var request = try request(path: from, method: "COPY")
        request.setValue(try url(for: to).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, method: "COPY", allowed: [200, 201, 204, 207])
    }

    public func upload(localURL: URL, remotePath: String) async throws -> TaskID {
        var request = try request(path: remotePath, method: "PUT")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        request.httpBody = try Data(contentsOf: localURL)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, method: "PUT", allowed: [201])
        return UUID()
    }

    public func download(remotePath: String, localURL: URL) async throws -> TaskID {
        guard !FileManager.default.fileExists(atPath: localURL.path) else {
            throw OpenFinderError.operationFailed("Local destination already exists: \(localURL.path)")
        }
        let (data, response) = try await session.data(for: request(path: remotePath, method: "GET"))
        try validate(response, data: data, method: "GET", allowed: [200])
        try data.write(to: localURL, options: .withoutOverwriting)
        return UUID()
    }

    private func request(path: String, method: String) throws -> URLRequest {
        let targetURL = try url(for: path)
        var request = URLRequest(url: targetURL)
        request.httpMethod = method
        request.setValue("OpenFinder/0.1", forHTTPHeaderField: "User-Agent")
        if let username = account.username {
            guard targetURL.scheme == "https" || account.options["allowInsecureHTTP"] == "true" else {
                throw OpenFinderError.operationFailed("Credentialed WebDAV accounts require HTTPS")
            }
            guard let secretRef = account.secretKeychainRef else {
                throw OpenFinderError.missingSecret("webdav.\(account.id).password")
            }
            guard let password = try credentialStore.secret(for: secretRef) else {
                throw OpenFinderError.missingSecret(secretRef)
            }
            let raw = "\(username):\(password)"
            request.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        } else if let secretRef = account.secretKeychainRef, try credentialStore.secret(for: secretRef) == nil {
            throw OpenFinderError.missingSecret(secretRef)
        }
        return request
    }

    private func url(for remotePath: String) throws -> URL {
        guard let baseURL = account.baseURL else { throw OpenFinderError.operationFailed("WebDAV account has no base URL") }
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        let trimmed = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encoded = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(charactersIn: "/?#[]@!$&'()*+,;=")) ?? String(component)
            }
            .joined(separator: "/")
        guard let url = URL(string: base + encoded) else { throw OpenFinderError.operationFailed("Invalid WebDAV path \(remotePath)") }
        return url
    }

    private func validate(_ response: URLResponse, data: Data, method: String, allowed: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenFinderError.operationFailed("Missing HTTP response") }
        guard allowed.contains(http.statusCode) else { throw OpenFinderError.webDAVUnexpectedStatus(http.statusCode, method) }
        if http.statusCode == 207, method != "PROPFIND" {
            try WebDAVStatusValidator.validateMultiStatus(data: data, method: method)
        }
    }


    private static func item(_ item: RemoteItem, relativeToBasePath basePath: String) -> RemoteItem {
        let relativePath = relativeRemotePath(from: item.path, basePath: basePath)
        return RemoteItem(
            id: "webdav:\(relativePath)",
            name: item.name,
            path: relativePath,
            kind: item.kind,
            size: item.size,
            modificationDate: item.modificationDate,
            etag: item.etag,
            mimeType: item.mimeType
        )
    }

    private static func relativeRemotePath(from hrefPath: String, basePath: String) -> String {
        let decoded = hrefPath.removingPercentEncoding ?? hrefPath
        let hrefOnlyPath: String
        if let absolute = URL(string: decoded), absolute.scheme != nil {
            hrefOnlyPath = absolute.path
        } else {
            hrefOnlyPath = decoded
        }
        let normalizedBase = normalizedRemotePath(basePath)
        var normalized = normalizedRemotePath(hrefOnlyPath)
        if normalizedBase != "/", normalized == normalizedBase {
            return "/"
        }
        if normalizedBase != "/", normalized.hasPrefix(normalizedBase + "/") {
            normalized.removeFirst(normalizedBase.count)
        }
        if normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized.isEmpty ? "/" : normalized
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/" + trimmed
    }

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8" ?>
    <D:propfind xmlns:D="DAV:">
      <D:prop>
        <D:resourcetype/>
        <D:getcontentlength/>
        <D:getlastmodified/>
        <D:getetag/>
        <D:getcontenttype/>
        <D:displayname/>
      </D:prop>
    </D:propfind>
    """
}


final class WebDAVStatusValidator: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""
    private var statusCodes: [Int] = []

    static func validateMultiStatus(data: Data, method: String) throws {
        guard !data.isEmpty else { return }
        let delegate = WebDAVStatusValidator()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? OpenFinderError.operationFailed("Could not parse WebDAV multistatus")
        }
        if let failure = delegate.statusCodes.first(where: { $0 >= 400 }) {
            throw OpenFinderError.webDAVUnexpectedStatus(failure, method)
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = localName(elementName)
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard localName(elementName) == "status" else { currentText = ""; return }
        let parts = currentText.split(separator: " ")
        if parts.count >= 2, let code = Int(parts[1]) {
            statusCodes.append(code)
        }
        currentText = ""
    }

    private func localName(_ name: String) -> String {
        if let colon = name.lastIndex(of: ":") { return String(name[name.index(after: colon)...]) }
        return name
    }
}

private extension CharacterSet {
    func subtracting(charactersIn string: String) -> CharacterSet {
        var copy = self
        copy.remove(charactersIn: string)
        return copy
    }
}

final class WebDAVMultiStatusParser: NSObject, XMLParserDelegate {
    private var items: [RemoteItem] = []
    private var currentElement = ""
    private var currentText = ""
    private var href: String?
    private var displayName: String?
    private var contentLength: Int64?
    private var contentType: String?
    private var lastModified: Date?
    private var etag: String?
    private var isCollection = false
    private var insideResponse = false

    static func parse(data: Data) throws -> [RemoteItem] {
        let delegate = WebDAVMultiStatusParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? OpenFinderError.operationFailed("Could not parse WebDAV XML")
        }
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let name = localName(elementName)
        currentElement = name
        currentText = ""
        if name == "response" {
            insideResponse = true
            href = nil
            displayName = nil
            contentLength = nil
            contentType = nil
            lastModified = nil
            etag = nil
            isCollection = false
        } else if insideResponse && name == "collection" {
            isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard insideResponse else { return }
        switch name {
        case "href": href = text
        case "displayname": displayName = text
        case "getcontentlength": contentLength = Int64(text)
        case "getcontenttype": contentType = text
        case "getetag": etag = text
        case "getlastmodified": lastModified = Self.httpDateFormatter.date(from: text)
        case "response":
            if let href {
                let decodedPath = href.removingPercentEncoding ?? href
                let name = (displayName?.isEmpty == false ? displayName : URL(string: decodedPath)?.lastPathComponent) ?? decodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                items.append(RemoteItem(id: "webdav:\(decodedPath)", name: name, path: decodedPath, kind: isCollection ? .directory : .file, size: contentLength, modificationDate: lastModified, etag: etag, mimeType: contentType))
            }
            insideResponse = false
        default: break
        }
        currentText = ""
    }

    private func localName(_ name: String) -> String {
        if let colon = name.lastIndex(of: ":") { return String(name[name.index(after: colon)...]) }
        return name
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
