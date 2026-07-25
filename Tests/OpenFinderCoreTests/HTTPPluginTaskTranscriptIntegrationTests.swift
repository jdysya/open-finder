import Foundation
import GRDB
import XCTest
@testable import OpenFinderCore

final class HTTPPluginTaskTranscriptIntegrationTests: XCTestCase {
    func testExistingHTTPTaskPersistsFourAnalysisProgressLogs() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.cleanup() }

        let taskID = try await fixture.run()
        let persisted = try await fixture.persistedLogs(taskID: taskID)

        XCTAssertEqual(persisted.status, .succeeded)
        XCTAssertEqual(persisted.messages.filter { !$0.hasPrefix("http.transcript.") }, [
            "sceneDetection: scene 1/1",
            "keyframeExtraction: frame 1/2",
            "tagAnalysis: frame 2/2",
            "reportGeneration: report 1/1"
        ])
    }

    func testHTTPTaskPersistsSafeOrderedTransportTranscriptWithoutInputSentinels() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.cleanup() }

        let taskID = try await fixture.run()
        let persisted = try await fixture.persistedLogs(taskID: taskID)

        XCTAssertEqual(persisted.status, .succeeded)
        XCTAssertEqual(persisted.messages.filter { $0.hasPrefix("http.transcript.") }, [
            "http.transcript.request taskID=\(taskID.uuidString) pluginID=dev.openfinder.plugins.video-analyzer actionID=analyze-video method=POST path=/openfinder/plugin/v1/jobs",
            "http.transcript.accepted taskID=\(taskID.uuidString) pluginID=dev.openfinder.plugins.video-analyzer actionID=analyze-video method=POST path=/openfinder/plugin/v1/jobs status=202 remoteJobID=\(taskID.uuidString)",
            "http.transcript.sse taskID=\(taskID.uuidString) pluginID=dev.openfinder.plugins.video-analyzer actionID=analyze-video kind=progress stage=sceneDetection completed=1 total=1 unit=scenes",
            "http.transcript.sse taskID=\(taskID.uuidString) pluginID=dev.openfinder.plugins.video-analyzer actionID=analyze-video kind=progress stage=keyframeExtraction completed=1 total=2 unit=frames",
            "http.transcript.sse taskID=\(taskID.uuidString) pluginID=dev.openfinder.plugins.video-analyzer actionID=analyze-video kind=progress stage=tagAnalysis completed=2 total=2 unit=frames",
            "http.transcript.sse taskID=\(taskID.uuidString) pluginID=dev.openfinder.plugins.video-analyzer actionID=analyze-video kind=progress stage=reportGeneration completed=1 total=1 unit=reports",
            "http.transcript.sse taskID=\(taskID.uuidString) pluginID=dev.openfinder.plugins.video-analyzer actionID=analyze-video kind=result",
            "http.transcript.result.fetched taskID=\(taskID.uuidString) pluginID=dev.openfinder.plugins.video-analyzer actionID=analyze-video method=GET path=/openfinder/plugin/v1/jobs/\(taskID.uuidString.lowercased())/result status=200",
            "http.transcript.result.validated taskID=\(taskID.uuidString) pluginID=dev.openfinder.plugins.video-analyzer actionID=analyze-video schema=transcript.v1 byteCount=7 sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "http.transcript.result.committed taskID=\(taskID.uuidString) pluginID=dev.openfinder.plugins.video-analyzer actionID=analyze-video schema=transcript.v1"
        ])
        let allLogs = persisted.messages.joined(separator: "\n")
        XCTAssertFalse(allLogs.contains("token-SENTINEL"))
        XCTAssertFalse(allLogs.contains("query-SENTINEL"))
        XCTAssertFalse(allLogs.contains("filename-SENTINEL"))
    }
}

private struct TranscriptFixture {
    let root: URL
    let databaseURL: URL
    let taskStore: GRDBTaskStore
    let queue: TaskQueueService
    let taskID = Self.wireTaskID

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPPluginTaskTranscript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("tasks.sqlite")
        taskStore = GRDBTaskStore(database: try AppDatabase(url: databaseURL))
        let registry = TaskHandlerRegistry()
        let credentials = InMemoryKeychainStore()
        try credentials.setSecret("token-SENTINEL", for: "transcript.token")
        let runner = HTTPPluginRunner(
            transport: Self.transport(),
            credentialResolver: { try credentials.secret(for: $0) }
        )
        let coordinator = PluginExecutionCoordinator(
            runner: runner,
            connectionChecker: TranscriptReadyConnectionChecker(),
            credentialResolver: .init(
                keychainStore: credentials,
                localStore: LocalPluginCredentialStore()
            ),
            temporaryDirectory: root
        )
        try await registry.register(PluginExecuteTaskHandler(
            pluginResolver: .exact([Self.plugin(root: root)]),
            credentialResolver: .init(
                keychainStore: credentials,
                localStore: LocalPluginCredentialStore()
            ),
            coordinator: coordinator
        ).taskHandler)
        queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry, store: taskStore)
    }

    func run() async throws -> UUID {
        let descriptor = try Self.envelope().makeDescriptor(
            taskID: taskID,
            resourceKey: "transcript",
            idempotencyKey: "transcript",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: 1
        )
        _ = try await queue.enqueue(.init(kind: .plugin(
            pluginID: "dev.openfinder.plugins.video-analyzer", actionID: "analyze-video"
        ), title: "Transcript", descriptor: descriptor))
        _ = try await queue.waitForTerminalStatus(taskID, timeout: 2)
        return taskID
    }

    func persistedLogs(taskID: UUID) async throws -> (status: TaskStatus, messages: [String]) {
        let database = try AppDatabase(url: databaseURL)
        return try await database.databasePool.read { db in
            let status = try TaskStatus(rawValue: String.fetchOne(
                db, sql: "SELECT status FROM task_records WHERE task_id = ?", arguments: [taskID.uuidString]
            ) ?? "") ?? .failed
            let messages = try String.fetchAll(
                db,
                sql: "SELECT message FROM task_logs WHERE task_id = ? ORDER BY sequence",
                arguments: [taskID.uuidString]
            )
            return (status, messages)
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private static func plugin(root: URL) -> LoadedPlugin {
        LoadedPlugin(manifest: .init(
            schemaVersion: 2,
            id: "dev.openfinder.plugins.video-analyzer",
            name: "Transcript",
            version: "0.1.0",
            description: nil,
            author: nil,
            execution: .http(
                protocolVersion: 1,
                endpointConfigurationKey: "serverURL",
                tokenSecretKey: "serverToken"
            ),
            actions: [.init(
                id: "analyze-video",
                title: "Transcript",
                category: nil,
                selection: .init(),
                match: nil,
                output: .init(resultType: "transcript.v1", canCopyToClipboard: false)
            )],
            permissions: .init(
                readFiles: "selected",
                writeFiles: "taskOutput",
                network: .init(required: true, hosts: ["127.0.0.1"]),
                clipboardWrite: false,
                clipboardRead: false,
                keychainSecrets: ["serverToken"],
                remoteAccounts: false,
                runExternalCommands: false
            ),
            configuration: [
                .init(key: "serverURL", type: "url", title: "Server"),
                .init(key: "controlQuery", type: "string", title: "Control")
            ]
        ), directory: root)
    }

    private static func envelope() -> PluginTaskEnvelope {
        .init(
            pluginID: "dev.openfinder.plugins.video-analyzer",
            pluginVersion: "0.1.0",
            actionID: "analyze-video",
            resultSchemaID: "transcript.v1",
            outputPolicy: .init(canCopyToClipboard: false),
            app: .init(name: "OpenFinder", version: "test"),
            context: .init(activePane: "left", currentLocation: .local(path: "/safe")),
            inputs: [.init(
                location: .local(path: "/safe/filename-SENTINEL.mov"),
                identity: .init(
                    id: "safe-file",
                    name: "filename-SENTINEL.mov",
                    kind: .file,
                    size: 7,
                    modificationDate: nil,
                    uti: nil,
                    mimeType: "video/quicktime",
                    fileExtension: "mov"
                )
            )],
            configuration: [
                "serverURL": "http://127.0.0.1:8765",
                "controlQuery": "query-SENTINEL"
            ],
            secretReferences: ["serverToken": "transcript.token"],
            workspacePolicy: .taskScopedTemporary
        )
    }

    private static func transport() -> ScriptedHTTPPluginTransport {
        ScriptedHTTPPluginTransport { request, _ in
            guard let path = request.url?.path else { throw URLError(.badURL) }
            if path.hasSuffix("/health") { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.health) }
            if path.hasSuffix("/capabilities") { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.capabilities()) }
            if request.httpMethod == "POST" { return HTTPPluginResponseFixture.data(snapshot(state: "queued", eventID: 0), status: 202) }
            if path.hasSuffix("/result") { return HTTPPluginResponseFixture.data(result()) }
            throw URLError(.badServerResponse)
        } stream: { _, _ in
            HTTPPluginResponseFixture.stream(progressFrames() + [
                HTTPPluginResponseFixture.frame(result(), id: 5, type: "result")
            ])
        }
    }

    private static func progressFrames() -> [String] {
        [
            progress(eventID: 1, phase: "sceneDetection", message: "scene 1/1", completed: 1, total: 1, unit: "scenes"),
            progress(eventID: 2, phase: "keyframeExtraction", message: "frame 1/2", completed: 1, total: 2, unit: "frames"),
            progress(eventID: 3, phase: "tagAnalysis", message: "frame 2/2", completed: 2, total: 2, unit: "frames"),
            progress(eventID: 4, phase: "reportGeneration", message: "report 1/1", completed: 1, total: 1, unit: "reports")
        ].enumerated().map { index, value in HTTPPluginResponseFixture.frame(value, id: index + 1, type: "progress") }
    }

    private static func progress(eventID: Int, phase: String, message: String, completed: Int, total: Int, unit: String) -> String {
        #"{"schemaVersion":1,"eventID":\#(eventID),"taskID":"\#(wireTaskID.uuidString)","type":"progress","fraction":0.5,"message":"\#(message)","phase":"\#(phase)","completed":\#(completed),"total":\#(total),"unit":"\#(unit)"}"#
    }

    private static func snapshot(state: String, eventID: Int) -> String {
        #"{"schemaVersion":1,"taskID":"\#(wireTaskID.uuidString)","state":"\#(state)","createdAt":"2026-07-16T00:00:00Z","updatedAt":"2026-07-16T00:00:01Z","startedAt":null,"finishedAt":null,"lastEventID":\#(eventID),"resultAvailable":false}"#
    }

    private static func result() -> String {
        #"{"schemaVersion":1,"eventID":5,"taskID":"\#(wireTaskID.uuidString)","type":"result","status":"success","artifacts":[{"artifactID":"11111111-1111-1111-1111-111111111111","type":"transcript.v1","relativePath":"analysis.json","mediaType":"application/json","byteCount":7,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}"#
    }

    private static let wireTaskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
}

private struct TranscriptReadyConnectionChecker: PluginConnectionChecking {
    func check(manifest: PluginManifest, values: [String: String], secretReferences: [String: String]) async -> PluginConnectionStatus {
        .init(state: .ready, guidance: "ready", protocolVersion: 1, pluginID: manifest.id, pluginVersion: manifest.version)
    }
}
