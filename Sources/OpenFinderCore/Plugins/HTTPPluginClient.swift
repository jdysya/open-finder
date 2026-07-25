import Foundation

public struct HTTPPluginTranscript: Sendable {
    public let message: String

    static func request(taskID: UUID, pluginID: String, actionID: String) -> Self {
        .init("http.transcript.request \(identity(taskID, pluginID, actionID)) method=POST path=/openfinder/plugin/v1/jobs")
    }

    static func accepted(taskID: UUID, pluginID: String, actionID: String, status: Int) -> Self {
        .init("http.transcript.accepted \(identity(taskID, pluginID, actionID)) method=POST path=/openfinder/plugin/v1/jobs status=\(status) remoteJobID=\(taskID.uuidString)")
    }

    static func sse(taskID: UUID, pluginID: String, actionID: String, event: HTTPPluginEvent) -> Self {
        let prefix = "http.transcript.sse \(identity(taskID, pluginID, actionID))"
        switch event.pluginOutputEvent {
        case .log: return .init("\(prefix) kind=log")
        case .progress(let progress):
            return .init("\(prefix) kind=progress stage=\(safe(progress.phase)) completed=\(progress.completed.map(String.init) ?? "none") total=\(progress.total.map(String.init) ?? "none") unit=\(safe(progress.unit))")
        case .result: return .init("\(prefix) kind=result")
        }
    }

    static func resultFetched(taskID: UUID, pluginID: String, actionID: String, status: Int) -> Self {
        .init("http.transcript.result.fetched \(identity(taskID, pluginID, actionID)) method=GET path=/openfinder/plugin/v1/jobs/\(taskID.uuidString.lowercased())/result status=\(status)")
    }

    static func resultValidated(taskID: UUID, pluginID: String, actionID: String, schema: String, artifacts: [HTTPPluginArtifact]) -> Self {
        let bytes = artifacts.reduce(0) { $0 + $1.byteCount }
        let hashes = artifacts.map(\.sha256).joined(separator: ",")
        return .init("http.transcript.result.validated \(identity(taskID, pluginID, actionID)) schema=\(safe(schema)) byteCount=\(bytes) sha256=\(hashes.isEmpty ? "none" : hashes)")
    }

    static func resultCommitted(taskID: UUID, pluginID: String, actionID: String, schema: String) -> Self {
        .init("http.transcript.result.committed \(identity(taskID, pluginID, actionID)) schema=\(safe(schema))")
    }

    private init(_ message: String) { self.message = message }

    private static func identity(_ taskID: UUID, _ pluginID: String, _ actionID: String) -> String {
        "taskID=\(taskID.uuidString) pluginID=\(safe(pluginID)) actionID=\(safe(actionID))"
    }

    private static func safe(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.utf8.count <= 64,
              value.utf8.allSatisfy({ byte in
                  (0x30 ... 0x39).contains(byte) || (0x41 ... 0x5a).contains(byte)
                      || (0x61 ... 0x7a).contains(byte) || [0x2d, 0x2e, 0x5f].contains(byte)
              })
        else { return "redacted" }
        return value
    }
}

struct HTTPPluginClient: Sendable {
    let endpoint: HTTPPluginEndpoint
    let token: String
    let transport: any HTTPPluginTransportProtocol

    func negotiate(manifest: PluginManifest, action: PluginActionManifest) async throws -> HTTPPluginCapabilities {
        let healthData = try await json(route: ["health"])
        let health = try HTTPPluginWire.health(healthData)
        guard health.status != "unavailable",
              health.pluginID == manifest.id,
              health.pluginVersion != nil else {
            throw HTTPPluginError.invalidResponse("health plugin identity or availability")
        }

        let capabilitiesData = try await json(route: ["capabilities"])
        let capabilities = try HTTPPluginWire.capabilities(capabilitiesData)
        guard capabilities.pluginID == manifest.id,
              capabilities.actions.contains(where: { $0.id == action.id }),
              capabilities.features.sse || capabilities.features.polling,
              capabilities.features.cancellation, capabilities.features.fileArtifacts else {
            throw HTTPPluginError.invalidResponse("capability plugin, action, or transport")
        }
        return capabilities
    }

    func submit(input: PluginInput) async throws -> (snapshot: HTTPPluginSnapshot, statusCode: Int) {
        let body = try JSONEncoder.openFinder.encode(input)
        let response = try await jsonResponse(route: ["jobs"], method: "POST", body: body, accepted: [200, 202])
        return (try HTTPPluginWire.snapshot(response.body, taskID: input.taskID), response.statusCode)
    }

    func snapshot(taskID: UUID) async throws -> HTTPPluginSnapshot {
        try HTTPPluginWire.snapshot(try await json(route: ["jobs", taskID.uuidString.lowercased()]), taskID: taskID)
    }

    func result(taskID: UUID) async throws -> (event: HTTPPluginEvent, statusCode: Int) {
        let response = try await jsonResponse(route: ["jobs", taskID.uuidString.lowercased(), "result"])
        return (try HTTPPluginWire.result(response.body, taskID: taskID), response.statusCode)
    }

    func stream(taskID: UUID, cursor: Int) async throws -> HTTPPluginStreamResponse {
        let request = HTTPPluginRequestFactory.make(
            endpoint: endpoint, route: ["jobs", taskID.uuidString.lowercased(), "events"],
            token: token, accept: "text/event-stream", cursor: cursor
        )
        return try await transport.stream(for: request)
    }

    func cancellationRequest(taskID: UUID) -> URLRequest {
        HTTPPluginRequestFactory.make(endpoint: endpoint,
                                      route: ["jobs", taskID.uuidString.lowercased()], method: "DELETE", token: token)
    }

    private func json(
        route: [String], method: String = "GET", body: Data? = nil, accepted: Set<Int> = [200]
    ) async throws -> Data {
        try await jsonResponse(route: route, method: method, body: body, accepted: accepted).body
    }

    private func jsonResponse(
        route: [String], method: String = "GET", body: Data? = nil, accepted: Set<Int> = [200]
    ) async throws -> HTTPPluginDataResponse {
        let request = HTTPPluginRequestFactory.make(endpoint: endpoint, route: route, method: method,
                                                    token: token, body: body)
        let response = try await transport.data(for: request)
        _ = try HTTPPluginResponseValidator.data(response, accepted: accepted, token: token)
        return response
    }
}
