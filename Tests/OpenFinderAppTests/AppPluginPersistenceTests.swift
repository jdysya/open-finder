import CryptoKit
import Foundation
import GRDB
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppPluginPersistenceTests: XCTestCase {
    func testProductionApplicationServicesProcessInlineMediaAnalysisPersists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductionAppProcessPersistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("tasks.sqlite")
        let input = root.appendingPathComponent("tone.aiff")
        try Data("tone".utf8).write(to: input)
        let script = root.appendingPathComponent("fixture.sh")
        try Data(Self.inlineProcessFixture.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        let services = ApplicationServices(dependencies: .init(
            supportDirectory: root,
            taskDatabaseURL: databaseURL
        ))
        let app = AppModel(services: services, startAutomatically: false)
        let (plugin, action) = inlineProcessPlugin(root: root)
        let item = FileItem(
            id: input.path,
            name: input.lastPathComponent,
            location: .local(path: input.path),
            kind: .file,
            size: 4,
            modificationDate: nil,
            creationDate: nil,
            uti: "public.aiff-audio",
            mimeType: "audio/aiff",
            fileExtension: "aiff",
            isHidden: false,
            isReadable: true,
            isWritable: true
        )

        app.runPlugin(plugin, action: action, items: [item], pane: app.leftPane)
        try await AppPluginFixture.waitUntil {
            let records = await app.taskQueue.history()
            return records.count == 1 && records[0].status == .succeeded
        }

        let records = await app.taskQueue.history()
        let taskID = try XCTUnwrap(records.first?.id)
        _ = ApplicationServices(dependencies: .init(
            supportDirectory: root,
            taskDatabaseURL: databaseURL
        ))
        let database = try AppDatabase(url: databaseURL)
        let persisted = try await database.databasePool.read { db in
            (
                effectsCommitted: try Double.fetchOne(
                    db,
                    sql: "SELECT effects_committed_at FROM task_records WHERE task_id = ?",
                    arguments: [taskID.uuidString]
                ),
                mediaCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM media_analysis_documents WHERE task_id = ?",
                    arguments: [taskID.uuidString]
                ) ?? -1
            )
        }

        XCTAssertNil(services.databaseOpenError)
        XCTAssertNotNil(services.artifactResults)
        XCTAssertNotNil(persisted.effectsCommitted)
        XCTAssertEqual(persisted.mediaCount, 1)
        print(
            "PRODUCTION_WIRING taskID=\(taskID) databaseOpen=true " +
                "artifactResults=true effectsCommitted=true mediaCount=1 restart=true"
        )
    }

    func testProcessInlineMediaAnalysisCommitsEffectsAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppProcessPluginPersistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("open-finder.sqlite")
        let input = root.appendingPathComponent("tone.aiff")
        try Data("tone".utf8).write(to: input)
        let script = root.appendingPathComponent("fixture.sh")
        try Data(Self.inlineProcessFixture.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        let item = FileItem(
            id: input.path,
            name: input.lastPathComponent,
            location: .local(path: input.path),
            kind: .file,
            size: 4,
            modificationDate: nil,
            creationDate: nil,
            uti: "public.aiff-audio",
            mimeType: "audio/aiff",
            fileExtension: "aiff",
            isHidden: false,
            isReadable: true,
            isWritable: true
        )
        let app = AppPluginFixture.app(
            root: root,
            process: ProcessPluginRunner(),
            http: RecordingPluginRunner(),
            taskDatabaseURL: databaseURL
        )
        let (plugin, action) = inlineProcessPlugin(root: root)

        app.runPlugin(plugin, action: action, items: [item], pane: app.leftPane)
        try await AppPluginFixture.waitUntil {
            let records = await app.taskQueue.history()
            return records.count == 1 && records[0].status == .succeeded
        }

        let records = await app.taskQueue.history()
        let taskID = try XCTUnwrap(records.first?.id)
        _ = ApplicationServices(dependencies: .init(
            supportDirectory: root,
            taskDatabaseURL: databaseURL
        ))
        let database = try AppDatabase(url: databaseURL)
        let persisted = try await database.databasePool.read { db in
            (
                effectsCommitted: try Double.fetchOne(
                    db,
                    sql: "SELECT effects_committed_at FROM task_records WHERE task_id = ?",
                    arguments: [taskID.uuidString]
                ),
                artifactCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM task_artifacts WHERE task_id = ?",
                    arguments: [taskID.uuidString]
                ) ?? -1,
                mediaCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM media_analysis_documents WHERE task_id = ?",
                    arguments: [taskID.uuidString]
                ) ?? -1
            )
        }

        XCTAssertNotNil(persisted.effectsCommitted)
        XCTAssertEqual(persisted.artifactCount, 0)
        XCTAssertEqual(persisted.mediaCount, 1)
        print(
            "PROCESS_INLINE_PERSISTENCE taskID=\(taskID) effectsCommitted=true " +
                "artifactCount=0 mediaCount=1 restart=true"
        )
    }

    func testHTTPMediaAnalysisArtifactSurvivesApplicationServicesRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPluginPersistenceRestart-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("open-finder.sqlite")
        let video = root.appendingPathComponent("restart-video.mp4")
        try Data("restart-video".utf8).write(to: video)
        let item = FileItem(
            id: video.path,
            name: video.lastPathComponent,
            location: .local(path: video.path),
            kind: .file,
            size: 13,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: "video/mp4",
            fileExtension: "mp4",
            isHidden: false,
            isReadable: true,
            isWritable: true
        )
        let http = FileAnalysisPluginRunner(videoPath: video.path)
        let app = AppPluginFixture.app(
            root: root,
            process: RecordingPluginRunner(),
            http: http,
            taskDatabaseURL: databaseURL
        )
        let (plugin, action) = persistencePlugin(root: root)
        app.setPluginConfigValue("http://127.0.0.1:8765", pluginID: plugin.id, key: "serverURL")
        let secretSaved = await app.setPluginSecret(
            "fixture-token",
            pluginID: plugin.id,
            key: "serverToken"
        )
        XCTAssertTrue(secretSaved)

        app.runPlugin(plugin, action: action, items: [item], pane: app.leftPane)
        try await AppPluginFixture.waitUntil {
            let records = await app.taskQueue.history()
            return records.count == 1 && records[0].status == .succeeded
        }

        let captured = await http.captured()
        let request = try XCTUnwrap(captured.first)
        let workspaceRoot = URL(fileURLWithPath: request.input.tempDirectory)
            .deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceRoot.path))

        let restarted = ApplicationServices(dependencies: .init(
            supportDirectory: root,
            taskDatabaseURL: databaseURL
        ))
        let results = try XCTUnwrap(restarted.artifactResults)
        let committed = await results.query(
            taskID: request.input.taskID,
            schemaID: MediaAnalysisDocument.schemaIdentifier
        )
        let artifact = try XCTUnwrap(committed.first)
        let payload = try await results.open(artifact.id)
        let document = try JSONDecoder.openFinder.decode(MediaAnalysisDocument.self, from: payload)
        let artifactURL = try await results.fileURL(for: artifact.id)
        let restartedDatabase = try AppDatabase(url: databaseURL)
        let persistedPayload = try await restartedDatabase.databasePool.read { db in
            try Data.fetchOne(
                db,
                sql: """
                    SELECT payload
                    FROM media_analysis_documents
                    WHERE task_id = ?
                    """,
                arguments: [request.input.taskID.uuidString]
            )
        }
        let durableState = try await restartedDatabase.databasePool.read { db in
            (
                effectsCommitted: try Double.fetchOne(
                    db,
                    sql: "SELECT effects_committed_at FROM task_records WHERE task_id = ?",
                    arguments: [request.input.taskID.uuidString]
                ),
                artifactCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM task_artifacts WHERE task_id = ?",
                    arguments: [request.input.taskID.uuidString]
                ) ?? -1
            )
        }
        let persistedDocument = try JSONDecoder.openFinder.decode(
            MediaAnalysisDocument.self,
            from: try XCTUnwrap(persistedPayload)
        )

        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(artifact.state, .committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path))
        XCTAssertEqual(document.taskID, request.input.taskID)
        XCTAssertEqual(persistedDocument, document)
        XCTAssertEqual(document.items.first?.media.sourcePath, video.path)
        XCTAssertNotNil(durableState.effectsCommitted)
        XCTAssertEqual(durableState.artifactCount, 1)
        print(
            "ARTIFACT_RESTART_QA workspaceClean=true taskID=\(request.input.taskID) " +
                "artifactID=\(artifact.id) relativePath=\(artifact.relativePath) " +
                "sha256=\(artifact.sha256) documentID=\(document.documentID)"
        )
    }

    func testHTTPMediaAnalysisResultRemainsPresentedAfterWorkspaceCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPluginPersistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("video.mp4")
        try Data("video".utf8).write(to: video)
        let item = FileItem(
            id: video.path,
            name: video.lastPathComponent,
            location: .local(path: video.path),
            kind: .file,
            size: 5,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: "video/mp4",
            fileExtension: "mp4",
            isHidden: false,
            isReadable: true,
            isWritable: true
        )
        let process = RecordingPluginRunner()
        let http = FileAnalysisPluginRunner(videoPath: video.path)
        let keychain = InMemoryKeychainStore()
        let app = AppPluginFixture.app(root: root, process: process, http: http, keychain: keychain)
        let (plugin, action) = persistencePlugin(root: root)
        app.setPluginConfigValue("http://127.0.0.1:8765", pluginID: plugin.id, key: "serverURL")
        let secretSaved = await app.setPluginSecret("fixture-token", pluginID: plugin.id, key: "serverToken")
        XCTAssertTrue(secretSaved)

        app.runPlugin(plugin, action: action, items: [item], pane: app.leftPane)
        try await AppPluginFixture.waitUntil {
            let records = await app.taskQueue.history()
            return records.count == 1
                && records[0].status == .succeeded
                && app.presentedPluginResult != nil
        }

        let captured = await http.captured()
        let request = try XCTUnwrap(captured.first)
        let records = await app.taskQueue.history()
        XCTAssertEqual(records.map(\.id), [request.input.taskID])
        XCTAssertEqual(records.first?.status, .succeeded)
        let workspaceRoot = URL(fileURLWithPath: request.input.tempDirectory).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceRoot.path))
        let projection = try XCTUnwrap(app.presentedPluginResult)
        XCTAssertEqual(projection.resultSchemaID, MediaAnalysisDocument.schemaIdentifier)
        XCTAssertEqual(projection.handlerIdentifier, .mediaAnalysis)
        XCTAssertNotNil(projection.project(MediaAnalysisDocument.self))
        XCTAssertEqual(
            PluginRendererCatalog.standard.renderer(for: projection).identifier,
            .mediaAnalysis
        )
    }

    private func persistencePlugin(
        root: URL
    ) -> (LoadedPlugin, PluginActionManifest) {
        let action = PluginActionManifest(
            id: "analyze-video",
            title: "Analyze Video",
            category: nil,
            selection: .init(minItems: 1, maxItems: nil, allowDirectories: false),
            match: nil,
            output: .init(
                resultType: MediaAnalysisDocument.schemaIdentifier,
                canCopyToClipboard: false
            )
        )
        let manifest = PluginManifest(
            schemaVersion: 2,
            id: "fixture.persistence",
            name: "Video Analyzer",
            version: "1.0.0",
            description: nil,
            author: nil,
            execution: .http(protocolVersion: 1, endpointConfigurationKey: "serverURL", tokenSecretKey: "serverToken"),
            actions: [action],
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
            configuration: [.init(key: "serverURL", type: "string", title: "Server", required: true)]
        )
        return (LoadedPlugin(manifest: manifest, directory: root), action)
    }

    private func inlineProcessPlugin(
        root: URL
    ) -> (LoadedPlugin, PluginActionManifest) {
        let action = PluginActionManifest(
            id: "inspect-spectrum",
            title: "Inspect Spectrum",
            category: nil,
            selection: .init(minItems: 1, maxItems: 1, allowDirectories: false),
            match: nil,
            output: .init(
                resultType: MediaAnalysisDocument.schemaIdentifier,
                canCopyToClipboard: false
            )
        )
        let manifest = PluginManifest(
            schemaVersion: 1,
            id: "fixture.process.inline-media",
            name: "Inline Media Analyzer",
            version: "1.0.0",
            description: nil,
            author: nil,
            execution: .process(runtime: .shell, entry: "fixture.sh"),
            actions: [action],
            permissions: .init(
                readFiles: "selected",
                writeFiles: "taskOutput",
                network: .init(required: false, hosts: []),
                clipboardWrite: false,
                clipboardRead: false,
                keychainSecrets: [],
                remoteAccounts: false,
                runExternalCommands: true
            ),
            configuration: []
        )
        return (LoadedPlugin(manifest: manifest, directory: root), action)
    }

    private static let inlineProcessFixture = #"""
#!/bin/zsh
payload="$(cat)"
task_id="$(printf '%s' "$payload" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["taskID"])')"
/usr/bin/python3 -c 'import json,sys
task_id=sys.argv[1]
document={"schemaID":"mediaAnalysis.v1","schemaVersion":1,
"documentID":"11111111-1111-1111-1111-111111111111","taskID":task_id,
"items":[],"suggestedTags":[],"actions":[],"managedTagLedger":{"mediaEntries":[]},
"createdAt":"2025-01-01T00:00:00Z"}
print(json.dumps({"type":"result","status":"success","message":"inline complete","artifacts":[
{"type":"mediaAnalysis.v1","content":json.dumps(document,separators=(",",":"))}]}))' "$task_id"
"""#
}

private actor FileAnalysisPluginRunner: PluginRunner {
    private let videoPath: String
    private var requests: [PluginRunRequest] = []

    init(videoPath: String) {
        self.videoPath = videoPath
    }

    func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        requests.append(request)
        let output = URL(fileURLWithPath: request.input.outputDirectory, isDirectory: true)
        let result = MediaAnalysisDocument(
            documentID: request.input.taskID,
            taskID: request.input.taskID,
            items: [.init(
                media: .init(
                    stableID: "fixture-video",
                    sourcePath: videoPath,
                    displayName: "video.mp4"
                ),
                summaryMetrics: [.init(key: "totalFrames", value: 0, unit: .count)],
                facets: [],
                moments: [],
                suggestedTags: [],
                report: nil
            )],
            suggestedTags: [],
            actions: MediaAnalysisAction.standard,
            managedTagLedger: .init(mediaEntries: []),
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        let data = try JSONEncoder.openFinder.encode(result)
        try data.write(to: output.appendingPathComponent("result.json"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let artifact = PluginArtifact(
            type: MediaAnalysisDocument.schemaIdentifier,
            file: .init(
                artifactID: UUID(),
                relativePath: "result.json",
                mediaType: "application/json",
                byteCount: data.count,
                sha256: hash
            )
        )
        request.onEvent?(.progress(.init(
            fraction: 1,
            message: "1 of 1",
            phase: "finalizing",
            completed: 1,
            total: 1,
            unit: "videos"
        )))
        return .init(
            exitCode: 0,
            events: [.result(status: "success", message: "done", clipboard: nil, artifacts: [artifact])],
            stdout: "",
            stderr: ""
        )
    }

    func cancel(taskID: UUID) async {}
    func captured() -> [PluginRunRequest] { requests }
}
