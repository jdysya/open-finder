import Foundation

struct HTTPPluginDataResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

struct HTTPPluginStreamResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let chunks: AsyncThrowingStream<Data, Error>
}

protocol HTTPPluginTransportProtocol: Sendable {
    func data(for request: URLRequest) async throws -> HTTPPluginDataResponse
    func stream(for request: URLRequest) async throws -> HTTPPluginStreamResponse
}

struct URLSessionHTTPPluginTransport: HTTPPluginTransportProtocol {
    private let session: URLSession

    init(session: URLSession = URLSessionHTTPPluginTransport.secureSession()) {
        self.session = session
    }

    static func secureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> HTTPPluginDataResponse {
        let delegate = HTTPPluginRedirectDelegate()
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            let http = try Self.http(response)
            return .init(statusCode: http.statusCode, headers: Self.headers(http), body: data)
        } catch let error as HTTPPluginError {
            throw error
        } catch {
            throw HTTPPluginError.transport(Self.safeTransportMessage(error))
        }
    }

    func stream(for request: URLRequest) async throws -> HTTPPluginStreamResponse {
        let delegate = HTTPPluginRedirectDelegate()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            let http = try Self.http(response)
            let chunks = AsyncThrowingStream<Data, Error> { continuation in
                let reader = Task {
                    do {
                        var buffer = Data()
                        buffer.reserveCapacity(4_096)
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            buffer.append(byte)
                            if byte == 0x0a || buffer.count == 4_096 {
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        if !buffer.isEmpty { continuation.yield(buffer) }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: HTTPPluginError.transport(Self.safeTransportMessage(error)))
                    }
                }
                continuation.onTermination = { _ in reader.cancel() }
            }
            return .init(statusCode: http.statusCode, headers: Self.headers(http), chunks: chunks)
        } catch let error as HTTPPluginError {
            throw error
        } catch {
            throw HTTPPluginError.transport(Self.safeTransportMessage(error))
        }
    }

    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw HTTPPluginError.invalidResponse("non-HTTP response")
        }
        return response
    }

    private static func headers(_ response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, pair in
            guard let key = pair.key as? String else { return }
            result[key.lowercased()] = String(describing: pair.value)
        }
    }

    private static func safeTransportMessage(_ error: Error) -> String {
        if let urlError = error as? URLError { return "URL error \(urlError.code.rawValue)" }
        return String(describing: type(of: error))
    }
}

final class HTTPPluginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum HTTPPluginRequestFactory {
    static func make(
        endpoint: HTTPPluginEndpoint,
        route: [String], method: String = "GET", token: String,
        accept: String = "application/json", body: Data? = nil, cursor: Int? = nil
    ) -> URLRequest {
        var request = URLRequest(url: route.reduce(endpoint.baseURL) { $0.appendingPathComponent($1) })
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("1", forHTTPHeaderField: "OpenFinder-Plugin-Protocol")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let cursor { request.setValue(String(cursor), forHTTPHeaderField: "Last-Event-ID") }
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
