import Foundation

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

    func submit(input: PluginInput) async throws -> HTTPPluginSnapshot {
        let body = try JSONEncoder.openFinder.encode(input)
        let data = try await json(route: ["jobs"], method: "POST", body: body, accepted: [200, 202])
        return try HTTPPluginWire.snapshot(data, taskID: input.taskID)
    }

    func snapshot(taskID: UUID) async throws -> HTTPPluginSnapshot {
        try HTTPPluginWire.snapshot(try await json(route: ["jobs", taskID.uuidString.lowercased()]), taskID: taskID)
    }

    func result(taskID: UUID) async throws -> HTTPPluginEvent {
        try HTTPPluginWire.result(try await json(route: ["jobs", taskID.uuidString.lowercased(), "result"]), taskID: taskID)
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
        let request = HTTPPluginRequestFactory.make(endpoint: endpoint, route: route, method: method,
                                                    token: token, body: body)
        let response = try await transport.data(for: request)
        return try HTTPPluginResponseValidator.data(response, accepted: accepted, token: token)
    }
}
