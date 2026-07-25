import Foundation

public struct HTTPPluginRunner: PluginRunner {
    private let transport: any HTTPPluginTransportProtocol
    private let credentialResolver: @Sendable (String) throws -> String?
    private let sleep: HTTPPluginSleep
    private let cancellations: HTTPPluginCancellationRegistry

    public init(credentialStore: any KeychainStore) {
        self.init(transport: URLSessionHTTPPluginTransport(),
                  credentialResolver: { try credentialStore.secret(for: $0) })
    }

    public init(credentialResolver: PluginCredentialResolver) {
        self.init(transport: URLSessionHTTPPluginTransport(),
                  credentialResolver: { try credentialResolver.secret(for: $0) })
    }

    init(
        transport: any HTTPPluginTransportProtocol,
        credentialResolver: @escaping @Sendable (String) throws -> String?,
        sleep: @escaping HTTPPluginSleep = HTTPPluginSleeps.live,
        cancellations: HTTPPluginCancellationRegistry = HTTPPluginCancellationRegistry()
    ) {
        self.transport = transport
        self.credentialResolver = credentialResolver
        self.sleep = sleep
        self.cancellations = cancellations
    }

    init(
        transport: any HTTPPluginTransportProtocol,
        credentialResolver: PluginCredentialResolver,
        sleep: @escaping HTTPPluginSleep = HTTPPluginSleeps.live,
        cancellations: HTTPPluginCancellationRegistry = HTTPPluginCancellationRegistry()
    ) {
        self.init(
            transport: transport,
            credentialResolver: { try credentialResolver.secret(for: $0) },
            sleep: sleep,
            cancellations: cancellations
        )
    }

    public func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        try await withTaskCancellationHandler {
            do {
                return try await execute(request)
            } catch is CancellationError {
                await cancellations.cancel(taskID: request.input.taskID)
                await cancellations.unregister(taskID: request.input.taskID)
                throw CancellationError()
            } catch {
                await cancellations.unregister(taskID: request.input.taskID)
                throw error
            }
        } onCancel: {
            Task { await cancellations.cancel(taskID: request.input.taskID) }
        }
    }

    public func cancel(taskID: UUID) async {
        await cancellations.cancel(taskID: taskID)
    }

    private func execute(_ request: PluginRunRequest) async throws -> PluginRunResult {
        let prepared = try HTTPPluginEndpoint.prepare(request: request, credentialResolver: credentialResolver)
        let client = HTTPPluginClient(endpoint: prepared.endpoint, token: prepared.bearerToken, transport: transport)
        let capabilities = try await client.negotiate(manifest: request.manifest, action: request.action)
        await request.onHTTPTranscript?(HTTPPluginTranscript.request(
            taskID: prepared.input.taskID, pluginID: request.manifest.id, actionID: request.action.id
        ))
        let submission = try await client.submit(input: prepared.input)
        await request.onHTTPTranscript?(HTTPPluginTranscript.accepted(
            taskID: prepared.input.taskID, pluginID: request.manifest.id,
            actionID: request.action.id, status: submission.statusCode
        ))
        await cancellations.register(taskID: prepared.input.taskID) {
            await HTTPPluginCancellation.send(
                transport: transport, request: client.cancellationRequest(taskID: prepared.input.taskID),
                taskID: prepared.input.taskID, token: prepared.bearerToken, sleep: sleep
            )
        }
        try Task.checkCancellation()

        var events: [PluginOutputEvent] = []
        var cursor = 0
        if capabilities.features.sse,
           let result = try await consumeSSE(client: client, taskID: prepared.input.taskID,
                                             cursor: &cursor, events: &events, onEvent: request.onEvent,
                                             onHTTPTranscript: request.onHTTPTranscript,
                                             pluginID: request.manifest.id, actionID: request.action.id) {
            return try await finish(result, client: client, events: &events, onEvent: request.onEvent,
                                    onHTTPTranscript: request.onHTTPTranscript,
                                    pluginID: request.manifest.id, actionID: request.action.id,
                                    schema: request.action.output?.resultSchemaID ?? "unknown")
        }
        guard capabilities.features.polling else {
            throw HTTPPluginError.invalidResponse("event stream reconnects exhausted")
        }
        let result = try await poll(client: client, taskID: prepared.input.taskID,
                                    cursor: &cursor, events: &events, onEvent: request.onEvent)
        return try await finish(result, client: client, events: &events, onEvent: request.onEvent,
                                onHTTPTranscript: request.onHTTPTranscript,
                                pluginID: request.manifest.id, actionID: request.action.id,
                                schema: request.action.output?.resultSchemaID ?? "unknown")
    }

    private func consumeSSE(
        client: HTTPPluginClient, taskID: UUID, cursor: inout Int,
        events: inout [PluginOutputEvent], onEvent: (@Sendable (PluginOutputEvent) -> Void)?,
        onHTTPTranscript: (@Sendable (HTTPPluginTranscript) async -> Void)?, pluginID: String, actionID: String
    ) async throws -> HTTPPluginEvent? {
        let delays = [0.25, 0.5, 1.0]
        for attempt in 0 ... 3 {
            do {
                let response = try await client.stream(taskID: taskID, cursor: cursor)
                try await validateStreamResponse(response, token: client.token)
                var parser = ServerSentEventParser(expectedTaskID: taskID, lastEventID: cursor)
                var terminal: HTTPPluginEvent?
                for try await chunk in response.chunks {
                    try Task.checkCancellation()
                    for event in try parser.append(chunk) {
                        cursor = event.eventID
                        let output = HTTPPluginRedactor.event(event.pluginOutputEvent, token: client.token)
                        events.append(output)
                        await onHTTPTranscript?(HTTPPluginTranscript.sse(
                            taskID: taskID, pluginID: pluginID, actionID: actionID, event: event
                        ))
                        onEvent?(output)
                        if event.type == .result { terminal = event }
                    }
                }
                try parser.finish()
                return terminal
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ServerSentEventParserError {
                guard error == .truncatedEvent || error == .missingTerminalEvent else { throw error }
            } catch let error as HTTPPluginRetryableStreamError {
                _ = error
            } catch let error as HTTPPluginError {
                guard case .transport = error else { throw error }
            } catch let error as URLError {
                _ = error
            }
            if attempt < 3 { try await sleep(delays[attempt]) }
        }
        return nil
    }

    private func poll(
        client: HTTPPluginClient, taskID: UUID, cursor: inout Int,
        events: inout [PluginOutputEvent], onEvent: (@Sendable (PluginOutputEvent) -> Void)?
    ) async throws -> HTTPPluginEvent {
        while true {
            try Task.checkCancellation()
            let snapshot = try await client.snapshot(taskID: taskID)
            if let progress = snapshot.progress, progress.eventID > cursor {
                cursor = progress.eventID
                let event = HTTPPluginRedactor.event(.progress(.init(
                    fraction: progress.fraction, message: progress.message, phase: progress.phase,
                    completed: progress.completed, total: progress.total, unit: progress.unit
                )), token: client.token)
                events.append(event); onEvent?(event)
            }
            if snapshot.state.isTerminal {
                let result = try await client.result(taskID: taskID).event
                let expectedStatus: String = switch snapshot.state {
                case .succeeded: "success"
                case .failed: "failure"
                case .cancelled: "cancelled"
                default: throw HTTPPluginError.invalidResponse("nonterminal result state")
                }
                guard result.eventID == snapshot.lastEventID,
                      result.pluginOutputEvent.resultStatus == expectedStatus else {
                    throw HTTPPluginError.invalidResponse("terminal result cursor")
                }
                return result
            }
            try await sleep(1)
        }
    }

    private func finish(
        _ streamed: HTTPPluginEvent, client: HTTPPluginClient,
        events: inout [PluginOutputEvent], onEvent: (@Sendable (PluginOutputEvent) -> Void)?,
        onHTTPTranscript: (@Sendable (HTTPPluginTranscript) async -> Void)?, pluginID: String, actionID: String,
        schema: String
    ) async throws -> PluginRunResult {
        let response = try await client.result(taskID: streamed.taskID)
        let result = response.event
        await onHTTPTranscript?(HTTPPluginTranscript.resultFetched(
            taskID: streamed.taskID, pluginID: pluginID, actionID: actionID, status: response.statusCode
        ))
        guard result == streamed else { throw HTTPPluginError.invalidResponse("terminal result mismatch") }
        await onHTTPTranscript?(HTTPPluginTranscript.resultValidated(
            taskID: streamed.taskID, pluginID: pluginID, actionID: actionID,
            schema: schema, artifacts: result.artifacts
        ))
        let output = HTTPPluginRedactor.event(result.pluginOutputEvent, token: client.token)
        if events.last != output {
            events.append(output); onEvent?(output)
        }
        if result.pluginOutputEvent.resultStatus == "cancelled" { throw CancellationError() }
        let exitCode: Int32 = result.pluginOutputEvent.isFailureResult ? 1 : 0
        await cancellations.unregister(taskID: result.taskID)
        return .init(exitCode: exitCode, events: events, stdout: "", stderr: "")
    }

    private func validateStreamResponse(_ response: HTTPPluginStreamResponse, token: String) async throws {
        guard response.statusCode != 200 else { try HTTPPluginResponseValidator.stream(response); return }
        guard response.headers["openfinder-plugin-protocol"] == "1",
              HTTPPluginResponseValidator.isJSON(response.headers["content-type"]) else {
            throw HTTPPluginError.invalidResponse("stream error headers")
        }
        var body = Data()
        for try await chunk in response.chunks {
            guard chunk.count <= ServerSentEventParser.maximumEventBytes - body.count else {
                throw HTTPPluginError.invalidResponse("stream error envelope too large")
            }
            body.append(chunk)
        }
        let error = HTTPPluginWire.serverError(body, status: response.statusCode, token: token)
        if case .server(let status, _, _, let retryable) = error, (500 ... 599).contains(status), retryable {
            throw HTTPPluginRetryableStreamError()
        }
        throw error
    }
}

private struct HTTPPluginRetryableStreamError: Error {}
