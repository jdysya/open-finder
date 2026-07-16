import Foundation
@testable import OpenFinderCore

actor ScriptedHTTPPluginTransport: HTTPPluginTransportProtocol {
    typealias DataHandler = @Sendable (URLRequest, Int) async throws -> HTTPPluginDataResponse
    typealias StreamHandler = @Sendable (URLRequest, Int) async throws -> HTTPPluginStreamResponse

    private let dataHandler: DataHandler
    private let streamHandler: StreamHandler
    private var dataRequests: [URLRequest] = []
    private var streamRequests: [URLRequest] = []

    init(data: @escaping DataHandler, stream: @escaping StreamHandler) {
        dataHandler = data
        streamHandler = stream
    }

    func data(for request: URLRequest) async throws -> HTTPPluginDataResponse {
        let index = dataRequests.count
        dataRequests.append(request)
        return try await dataHandler(request, index)
    }

    func stream(for request: URLRequest) async throws -> HTTPPluginStreamResponse {
        let index = streamRequests.count
        streamRequests.append(request)
        return try await streamHandler(request, index)
    }

    func capturedDataRequests() -> [URLRequest] { dataRequests }
    func capturedStreamRequests() -> [URLRequest] { streamRequests }
}

actor HTTPPluginSleepRecorder {
    private var values: [Double] = []
    func record(_ value: Double) { values.append(value) }
    func captured() -> [Double] { values }
}

enum HTTPPluginResponseFixture {
    static let headers = [
        "openfinder-plugin-protocol": "1",
        "content-type": "application/json; charset=utf-8"
    ]
    static let streamHeaders = [
        "openfinder-plugin-protocol": "1",
        "content-type": "text/event-stream; charset=utf-8"
    ]

    static func data(_ json: String, status: Int = 200) -> HTTPPluginDataResponse {
        .init(statusCode: status, headers: headers, body: Data(json.utf8))
    }

    static func stream(_ parts: [String], status: Int = 200, headers: [String: String]? = nil) -> HTTPPluginStreamResponse {
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            parts.forEach { continuation.yield(Data($0.utf8)) }
            continuation.finish()
        }
        return .init(statusCode: status, headers: headers ?? streamHeaders, chunks: chunks)
    }

    static let health = #"{"schemaVersion":1,"protocolVersion":1,"status":"ready","pluginID":"dev.openfinder.plugins.video-analyzer","pluginVersion":"0.1.0","runtime":{"name":"Python","version":"3.12"},"checks":[]}"#

    static func capabilities(sse: Bool = true, polling: Bool = true) -> String {
        #"{"schemaVersion":1,"protocolVersion":1,"pluginID":"dev.openfinder.plugins.video-analyzer","pluginVersion":"0.1.0","actions":[{"id":"analyze-video"}],"features":{"sse":\#(sse),"polling":\#(polling),"cancellation":true,"fileArtifacts":true},"limits":{"maxRequestBytes":1048576,"terminalRetentionSeconds":1800,"maxEventsPerJob":10000,"maxQueuedJobs":100}}"#
    }

    static func snapshot(state: String, eventID: Int, progress: String? = nil) -> String {
        let value = progress.map { ",\"progress\":\($0)" } ?? ""
        let terminal = ["succeeded", "failed", "cancelled"].contains(state)
        return "{\"schemaVersion\":1,\"taskID\":\"11111111-1111-1111-1111-111111111111\",\"state\":\"\(state)\",\"createdAt\":\"2026-07-16T00:00:00Z\",\"updatedAt\":\"2026-07-16T00:00:01Z\",\"startedAt\":null,\"finishedAt\":null,\"lastEventID\":\(eventID),\"resultAvailable\":\(terminal)\(value)}"
    }

    static let progress = #"{"schemaVersion":1,"eventID":1,"taskID":"11111111-1111-1111-1111-111111111111","type":"progress","fraction":0.5,"message":"1/2","completed":1,"total":2,"unit":"frames"}"#
    static let result = #"{"schemaVersion":1,"eventID":2,"taskID":"11111111-1111-1111-1111-111111111111","type":"result","status":"success","artifacts":[]}"#
    static let failure = #"{"schemaVersion":1,"eventID":2,"taskID":"11111111-1111-1111-1111-111111111111","type":"result","status":"failure","message":"model failed","artifacts":[]}"#

    static func frame(_ json: String, id: Int, type: String) -> String {
        "id: \(id)\nevent: \(type)\ndata: \(json)\n\n"
    }

    static func request() -> PluginRunRequest {
        let manifest = HTTPPluginTestFixture.manifest()
        let input = HTTPPluginTestFixture.input(
            config: ["serverURL": "http://127.0.0.1:8765"],
            secrets: ["serverToken": .init(env: "keychain.video.token")]
        )
        return .init(manifest: manifest, action: manifest.actions[0], input: input, environment: [:],
                     pluginDirectory: URL(fileURLWithPath: "/tmp/plugin"), workingDirectory: URL(fileURLWithPath: "/tmp"))
    }
}
