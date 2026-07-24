import Foundation
import XCTest
@testable import OpenFinderCore

final class PluginTaskHandlerTests: XCTestCase {
    func testPluginDescriptorRoundTripsWithoutSecretValue() throws {
        let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let payload = PluginTaskEnvelope(
            pluginID: "fixture.process.media",
            pluginVersion: "1.2.3",
            actionID: "inspect",
            resultSchemaID: MediaAnalysisDocument.schemaIdentifier,
            outputPolicy: .init(canCopyToClipboard: false),
            app: .init(name: "OpenFinder", version: "test"),
            context: .init(activePane: "left", currentLocation: .local(path: "/fixture")),
            inputs: [.init(
                location: .local(path: "/fixture/demo.mov"),
                identity: .init(
                    id: "file-1",
                    name: "demo.mov",
                    kind: .file,
                    size: 42,
                    modificationDate: Date(timeIntervalSince1970: 1_735_689_600),
                    uti: "public.movie",
                    mimeType: "video/quicktime",
                    fileExtension: "mov"
                )
            )],
            configuration: ["quality": "accurate"],
            secretReferences: ["apiKey": "plugin.fixture.apiKey"],
            workspacePolicy: .taskScopedTemporary
        )

        let descriptor = try payload.makeDescriptor(
            taskID: taskID,
            resourceKey: "plugin:fixture:file-1",
            idempotencyKey: "plugin:fixture:inspect:file-1",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: 9
        )
        let encoded = try JSONEncoder.openFinder.encode(descriptor)
        let decodedDescriptor = try JSONDecoder.openFinder.decode(
            TaskDescriptorEnvelope.self,
            from: encoded
        )
        let decoded = try PluginTaskEnvelope.decode(from: decodedDescriptor)
        let persisted = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(descriptor.handlerID, "plugin.execute.v1")
        XCTAssertEqual(descriptor.payloadVersion, 1)
        XCTAssertEqual(descriptor.resourceKey, "plugin:fixture:file-1")
        XCTAssertEqual(descriptor.idempotencyKey, "plugin:fixture:inspect:file-1")
        XCTAssertEqual(descriptor.lineage.rootTaskID, taskID)
        XCTAssertEqual(descriptor.queueOrdinal, 9)
        XCTAssertTrue(persisted.contains("plugin.fixture.apiKey"))
        XCTAssertFalse(persisted.contains("fixture-secret-value"))
    }

    func testDescriptorFallbackFailureIsTypedAndNeverInfersSchema() throws {
        let id = UUID()
        let descriptor = TaskDescriptorEnvelope(
            taskID: id,
            handlerID: DurableTaskHandlerID.pluginExecute.rawValue,
            payloadVersion: 1,
            lineage: .init(rootTaskID: id),
            queueOrdinal: 1,
            redactedPayload: ["plugin": #"{"pluginID":"mediaAnalysis.v1"}"#]
        )

        XCTAssertThrowsError(try PluginTaskEnvelope.decode(from: descriptor)) { error in
            XCTAssertEqual(error as? PluginTaskEnvelopeError, .malformedPayload)
        }
    }

    func testConfigurationCannotContainCredentialKeys() throws {
        XCTAssertThrowsError(try makePayload(
            pluginID: "fixture",
            configuration: ["apiKey": "fixture-secret-value"],
            secretReferences: ["apiKey": "plugin.fixture.apiKey"]
        ).validated()) { error in
            XCTAssertEqual(
                error as? PluginTaskEnvelopeError,
                .configurationContainsSecretKey("apiKey")
            )
        }
    }

    func testTwoPluginsExecuteMediaAnalysisSchema() async throws {
        let fixture = try PluginTaskFixture()
        defer { fixture.cleanup() }
        let processPlugin = fixture.processPlugin
        let httpPlugin = fixture.httpPlugin
        let credentials = fixture.credentials
        let coordinator = PluginExecutionCoordinator(
            runner: PluginRunnerRouter(
                processRunner: ProcessPluginRunner(),
                httpRunner: HTTPPluginRunner(credentialResolver: credentials)
            ),
            connectionChecker: ExactReadyPluginConnectionChecker(),
            credentialResolver: credentials,
            temporaryDirectory: fixture.root
        )
        let resolver = PluginTaskPluginResolver.exact([processPlugin, httpPlugin])
        let handler = PluginExecuteTaskHandler(
            pluginResolver: resolver,
            credentialResolver: credentials,
            coordinator: coordinator
        )
        let registry = TaskHandlerRegistry()
        try await registry.register(handler.taskHandler)
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry)

        let processID = try await enqueue(
            plugin: processPlugin,
            configuration: [:],
            secretReferences: [:],
            queue: queue,
            root: fixture.root,
            ordinal: 1
        )
        let httpID = try await enqueue(
            plugin: httpPlugin,
            configuration: ["serverURL": fixture.server.endpoint],
            secretReferences: ["serverToken": fixture.credentialReference],
            queue: queue,
            root: fixture.root,
            ordinal: 2
        )
        let processRecord = try await queue.waitForTerminalStatus(processID, timeout: 8)
        let httpRecord = try await queue.waitForTerminalStatus(httpID, timeout: 8)
        let processLogs = await queue.logs(for: processID)
        let httpLogs = await queue.logs(for: httpID)
        let observations = try fixture.server.observations()
        let httpTaskRoot = fixture.root
            .appendingPathComponent("OpenFinderHTTPTasks", isDirectory: true)
            .appendingPathComponent(httpID.uuidString, isDirectory: true)

        XCTAssertEqual(processRecord.status, .succeeded)
        XCTAssertEqual(httpRecord.status, .succeeded)
        XCTAssertEqual(processRecord.resultSummary, "process complete")
        XCTAssertEqual(httpRecord.resultSummary, "Plugin completed")
        XCTAssertFalse(processLogs.description.contains(fixture.secret))
        XCTAssertFalse(httpLogs.description.contains(fixture.secret))
        XCTAssertTrue(observations.contains {
            $0.method == "POST"
                && $0.submittedTaskID == httpID
                && $0.submittedSecretsEmpty == true
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: httpTaskRoot.path))
        print(
            "PLUGIN_TASK_OBSERVABLE pluginIDs=\(processPlugin.id),\(httpPlugin.id) " +
            "versions=\(processPlugin.manifest.version),\(httpPlugin.manifest.version) " +
            "actions=\(processPlugin.manifest.actions[0].id),\(httpPlugin.manifest.actions[0].id) " +
            "schemas=mediaAnalysis.v1,mediaAnalysis.v1 secretInWire=false secretInLogs=false " +
            "httpWorkspaceClean=true"
        )
    }

    func testMissingExactPluginVersionActionAndCredentialBecomeUnavailable() async throws {
        let fixture = try PluginTaskFixture()
        defer { fixture.cleanup() }
        let credentials = fixture.credentials
        let coordinator = PluginExecutionCoordinator(
            runner: PluginRunnerRouter(
                processRunner: ProcessPluginRunner(),
                httpRunner: HTTPPluginRunner(credentialResolver: credentials)
            ),
            connectionChecker: HTTPPluginConnectionProbe(credentialResolver: credentials),
            credentialResolver: credentials,
            temporaryDirectory: fixture.root
        )
        let cases: [PluginTaskEnvelope] = [
            makePayload(pluginID: "missing.plugin"),
            makePayload(pluginID: fixture.processPlugin.id, pluginVersion: "9.9.9"),
            makePayload(pluginID: fixture.processPlugin.id, actionID: "missing-action"),
            makePayload(
                pluginID: fixture.processPlugin.id,
                configuration: ["removedConfigurationKey": "stale"]
            ),
            makePayload(
                pluginID: fixture.processPlugin.id,
                resultSchemaID: "mediaAnalysis.v999"
            ),
            makePayload(
                pluginID: fixture.httpPlugin.id,
                pluginVersion: fixture.httpPlugin.manifest.version,
                actionID: fixture.httpPlugin.manifest.actions[0].id,
                configuration: ["serverURL": fixture.server.endpoint],
                secretReferences: ["serverToken": "missing.reference"]
            )
        ]

        for (index, payload) in cases.enumerated() {
            let handler = PluginExecuteTaskHandler(
                pluginResolver: .exact([fixture.processPlugin, fixture.httpPlugin]),
                credentialResolver: credentials,
                coordinator: coordinator
            )
            let registry = TaskHandlerRegistry()
            try await registry.register(handler.taskHandler)
            let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry)
            let id = UUID()
            let descriptor = try payload.makeDescriptor(
                taskID: id,
                resourceKey: "unavailable:\(index)",
                idempotencyKey: "unavailable:\(index)",
                lineage: .init(rootTaskID: id),
                queueOrdinal: UInt64(index)
            )
            _ = try await queue.enqueue(.init(
                kind: .plugin(pluginID: payload.pluginID, actionID: payload.actionID),
                title: "Unavailable plugin fixture",
                descriptor: descriptor
            ))
            let record = try await queue.waitForTerminalStatus(id, timeout: 2)
            XCTAssertEqual(record.status, .unavailable)
            XCTAssertEqual(record.reasonCode, .handlerUnavailable)
        }
    }

    func testRetryUsesNewTaskIDAndPreservesImmutableSnapshot() async throws {
        let fixture = try PluginTaskFixture()
        defer { fixture.cleanup() }
        let plugin = fixture.processPlugin
        let coordinator = PluginExecutionCoordinator(
            runner: PluginRunnerRouter(
                processRunner: ProcessPluginRunner(),
                httpRunner: HTTPPluginRunner(credentialResolver: fixture.credentials)
            ),
            connectionChecker: HTTPPluginConnectionProbe(credentialResolver: fixture.credentials),
            credentialResolver: fixture.credentials,
            temporaryDirectory: fixture.root
        )
        let registry = TaskHandlerRegistry()
        try await registry.register(PluginExecuteTaskHandler(
            pluginResolver: .exact([plugin]),
            credentialResolver: fixture.credentials,
            coordinator: coordinator
        ).taskHandler)
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry)
        let firstID = try await enqueue(
            plugin: plugin,
            configuration: ["mode": "snapshot"],
            secretReferences: [:],
            queue: queue,
            root: fixture.root,
            ordinal: 3
        )
        _ = try await queue.waitForTerminalStatus(firstID, timeout: 4)

        let retryID = try await queue.retry(firstID)
        let retry = try await queue.waitForTerminalStatus(retryID, timeout: 4)
        let firstRecord = await queue.record(for: firstID)
        let first = try XCTUnwrap(firstRecord)

        XCTAssertNotEqual(firstID, retryID)
        XCTAssertEqual(retry.status, .succeeded)
        XCTAssertEqual(retry.descriptor?.redactedPayload, first.descriptor?.redactedPayload)
        XCTAssertEqual(retry.descriptor?.resourceKey, first.descriptor?.resourceKey)
        XCTAssertEqual(retry.descriptor?.idempotencyKey, first.descriptor?.idempotencyKey)
        XCTAssertEqual(retry.descriptor?.lineage.rootTaskID, firstID)
        XCTAssertEqual(retry.descriptor?.lineage.parentTaskID, firstID)
        XCTAssertEqual(retry.descriptor?.lineage.attempt, 2)
    }

    private func enqueue(
        plugin: LoadedPlugin,
        configuration: [String: String],
        secretReferences: [String: String],
        queue: TaskQueueService,
        root: URL,
        ordinal: UInt64
    ) async throws -> UUID {
        let payload = makePayload(
            pluginID: plugin.id,
            pluginVersion: plugin.manifest.version,
            actionID: plugin.manifest.actions[0].id,
            configuration: configuration,
            secretReferences: secretReferences,
            currentLocation: .local(path: root.path)
        )
        let id = UUID()
        let descriptor = try payload.makeDescriptor(
            taskID: id,
            resourceKey: "plugin:\(plugin.id)",
            idempotencyKey: "plugin:\(plugin.id):\(plugin.manifest.actions[0].id)",
            lineage: .init(rootTaskID: id),
            queueOrdinal: ordinal
        )
        return try await queue.enqueue(.init(
            kind: .plugin(pluginID: plugin.id, actionID: plugin.manifest.actions[0].id),
            title: plugin.manifest.name,
            descriptor: descriptor
        ))
    }

    private func makePayload(
        pluginID: String,
        pluginVersion: String = "1.2.3",
        actionID: String = "inspect",
        resultSchemaID: String = MediaAnalysisDocument.schemaIdentifier,
        configuration: [String: String] = [:],
        secretReferences: [String: String] = [:],
        currentLocation: Location = .local(path: "/fixture")
    ) -> PluginTaskEnvelope {
        PluginTaskEnvelope(
            pluginID: pluginID,
            pluginVersion: pluginVersion,
            actionID: actionID,
            resultSchemaID: resultSchemaID,
            outputPolicy: .init(canCopyToClipboard: false),
            app: .init(name: "OpenFinder", version: "test"),
            context: .init(activePane: "left", currentLocation: currentLocation),
            inputs: [],
            configuration: configuration,
            secretReferences: secretReferences,
            workspacePolicy: .taskScopedTemporary
        )
    }
}

private struct PluginTaskFixture {
    let root: URL
    let server: PortZeroHTTPCharacterizationServer
    let processPlugin: LoadedPlugin
    let httpPlugin: LoadedPlugin
    let credentials: PluginCredentialResolver
    let credentialReference = "fixture.http.token"
    let secret: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginTaskHandler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        server = try PortZeroHTTPCharacterizationServer(root: root, responseMode: .mediaAnalysis)
        secret = server.token
        let processDirectory = root.appendingPathComponent("process.plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: processDirectory, withIntermediateDirectories: true)
        try Data(Self.processFixture.utf8).write(
            to: processDirectory.appendingPathComponent("run.sh")
        )
        processPlugin = LoadedPlugin(
            manifest: Self.manifest(
                id: "fixture.process.media",
                version: "1.2.3",
                actionID: "inspect",
                execution: .process(runtime: .shell, entry: "run.sh")
            ),
            directory: processDirectory
        )
        httpPlugin = LoadedPlugin(
            manifest: Self.manifest(
                id: "dev.openfinder.plugins.video-analyzer",
                version: "0.1.0",
                actionID: "analyze-video",
                execution: .http(
                    protocolVersion: 1,
                    endpointConfigurationKey: "serverURL",
                    tokenSecretKey: "serverToken"
                )
            ),
            directory: root
        )
        let keychain = InMemoryKeychainStore()
        try keychain.setSecret(secret, for: credentialReference)
        credentials = PluginCredentialResolver(
            keychainStore: keychain,
            localStore: LocalPluginCredentialStore()
        )
    }

    func cleanup() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private static func manifest(
        id: String,
        version: String,
        actionID: String,
        execution: PluginExecution
    ) -> PluginManifest {
        let isHTTP = {
            if case .http = execution { true } else { false }
        }()
        return PluginManifest(
            schemaVersion: isHTTP ? 2 : 1,
            id: id,
            name: id,
            version: version,
            description: nil,
            author: nil,
            execution: execution,
            actions: [.init(
                id: actionID,
                title: actionID,
                category: nil,
                selection: .init(),
                match: nil,
                output: .init(
                    resultType: MediaAnalysisDocument.schemaIdentifier,
                    canCopyToClipboard: false
                )
            )],
            permissions: .init(
                readFiles: "selected",
                writeFiles: "taskOutput",
                network: .init(required: isHTTP, hosts: isHTTP ? ["127.0.0.1"] : []),
                clipboardWrite: false,
                clipboardRead: false,
                keychainSecrets: isHTTP ? ["serverToken"] : [],
                remoteAccounts: false,
                runExternalCommands: !isHTTP
            ),
            configuration: isHTTP
                ? [.init(key: "serverURL", type: "url", title: "Server")]
                : [.init(key: "mode", type: "string", title: "Mode")]
        )
    }

    private static let processFixture = #"""
#!/bin/zsh
payload="$(cat)"
task_id="$(printf '%s' "$payload" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["taskID"])')"
/usr/bin/python3 -c 'import json,sys
task_id=sys.argv[1]
document={"schemaID":"mediaAnalysis.v1","schemaVersion":1,
"documentID":"11111111-1111-1111-1111-111111111111","taskID":task_id,
"items":[],"suggestedTags":[],"actions":[],"managedTagLedger":{"mediaEntries":[]},
"createdAt":"2025-01-01T00:00:00Z"}
print(json.dumps({"type":"result","status":"success","message":"process complete","artifacts":[
{"type":"mediaAnalysis.v1","content":json.dumps(document,separators=(",",":"))}]}))' "$task_id"
"""#
}

private struct ExactReadyPluginConnectionChecker: PluginConnectionChecking {
    func check(
        manifest: PluginManifest,
        values: [String: String],
        secretReferences: [String: String]
    ) async -> PluginConnectionStatus {
        .init(
            state: .ready,
            guidance: "Exact fixture identity is ready.",
            protocolVersion: 1,
            pluginID: manifest.id,
            pluginVersion: manifest.version
        )
    }
}
