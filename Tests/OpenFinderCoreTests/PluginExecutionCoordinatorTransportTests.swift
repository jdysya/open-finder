import Foundation
import XCTest
@testable import OpenFinderCore

final class PluginExecutionCoordinatorTransportTests: XCTestCase {
    func testRealProcessAndPortZeroHTTPShareMediaHandler() async throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginCoordinatorTransports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try PortZeroHTTPCharacterizationServer(
            root: root,
            responseMode: .mediaAnalysis
        )
        defer { server.stop() }
        let processDirectory = root.appendingPathComponent("process.plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: processDirectory, withIntermediateDirectories: true)
        try Data(Self.processFixture.utf8).write(
            to: processDirectory.appendingPathComponent("run.sh")
        )
        let process = LoadedPlugin(
            manifest: manifest(
                id: "fixture.process.media",
                version: "1.2.3",
                actionID: "inspect",
                execution: .process(runtime: .shell, entry: "run.sh")
            ),
            directory: processDirectory
        )
        let http = LoadedPlugin(
            manifest: manifest(
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
        try keychain.setSecret(server.token, for: "fixture.http.token")
        let credentials = PluginCredentialResolver(
            keychainStore: keychain,
            localStore: LocalPluginCredentialStore()
        )
        let coordinator = PluginExecutionCoordinator(
            runner: PluginRunnerRouter(
                processRunner: ProcessPluginRunner(),
                httpRunner: HTTPPluginRunner(credentialResolver: credentials)
            ),
            connectionChecker: HTTPPluginConnectionProbe(credentialResolver: credentials),
            credentialResolver: credentials,
            temporaryDirectory: root
        )

        // When
        let processOutcome: PluginExecutionOutcome
        do {
            processOutcome = try await coordinator.execute(request(
                plugin: process,
                taskID: UUID(),
                root: root
            ))
        } catch {
            XCTFail("Real Process fixture failed: \(error)")
            throw error
        }
        let httpTaskID = UUID()
        let httpOutcome: PluginExecutionOutcome
        do {
            httpOutcome = try await coordinator.execute(request(
                plugin: http,
                taskID: httpTaskID,
                root: root,
                configuration: ["serverURL": server.endpoint],
                secretReferences: ["serverToken": "fixture.http.token"]
            ))
        } catch {
            XCTFail("Port-zero HTTP fixture failed: \(error)")
            throw error
        }

        // Then
        XCTAssertEqual(processOutcome.projection.handlerIdentifier, .mediaAnalysis)
        XCTAssertEqual(httpOutcome.projection.handlerIdentifier, .mediaAnalysis)
        XCTAssertEqual(
            processOutcome.projection.project(MediaAnalysisDocument.self)?.schemaID,
            MediaAnalysisDocument.schemaIdentifier
        )
        XCTAssertEqual(
            httpOutcome.projection.project(MediaAnalysisDocument.self)?.schemaID,
            MediaAnalysisDocument.schemaIdentifier
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "OpenFinderHTTPTasks/\(httpTaskID.uuidString)"
            ).path
        ))
        print(
            "ROUTING_OBSERVABLE transports=process,http schemas=mediaAnalysis.v1,mediaAnalysis.v1 "
                + "handler=mediaAnalysis.v1 pluginIDs=\(process.id),\(http.id)"
        )
    }

    private func manifest(
        id: String,
        version: String,
        actionID: String,
        execution: PluginExecution
    ) -> PluginManifest {
        let isHTTP: Bool
        switch execution {
        case .process: isHTTP = false
        case .http: isHTTP = true
        }
        return .init(
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
                : []
        )
    }

    private func request(
        plugin: LoadedPlugin,
        taskID: UUID,
        root: URL,
        configuration: [String: String] = [:],
        secretReferences: [String: String] = [:]
    ) -> PluginExecutionRequest {
        .init(
            plugin: plugin,
            pluginVersion: plugin.manifest.version,
            action: plugin.manifest.actions[0],
            taskID: taskID,
            app: .init(name: "OpenFinder", version: "test"),
            context: .init(activePane: "left", currentLocation: .local(path: root.path)),
            files: [],
            configurationValues: configuration,
            secretReferences: secretReferences
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
print(json.dumps({"type":"result","status":"success","artifacts":[
{"type":"mediaAnalysis.v1","content":json.dumps(document,separators=(",",":"))}]}))' "$task_id"
"""#
}
