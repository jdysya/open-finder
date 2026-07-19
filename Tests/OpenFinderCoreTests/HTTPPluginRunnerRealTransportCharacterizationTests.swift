import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginRunnerRealTransportCharacterizationTests: XCTestCase {
    func testCurrentURLSessionRunnerUsesExactHTTPProtocolSequence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPRunnerCharacterization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try PortZeroHTTPCharacterizationServer(root: root)
        defer { server.stop() }
        let manifest = HTTPPluginTestFixture.manifest()
        let keychain = InMemoryKeychainStore()
        try keychain.setSecret(server.token, for: "characterization.token")
        let input = PluginInput(
            schemaVersion: 1, taskID: HTTPPluginTestFixture.taskID, actionID: manifest.actions[0].id,
            app: .init(name: "OpenFinder", version: "0.1.0"),
            context: .init(activePane: "left", currentLocation: .local(path: root.path)), files: [],
            config: ["serverURL": server.endpoint],
            secrets: ["serverToken": .init(env: "characterization.token")],
            tempDirectory: root.appendingPathComponent("temp").path,
            outputDirectory: root.appendingPathComponent("output").path
        )
        let request = PluginRunRequest(
            manifest: manifest, action: manifest.actions[0], input: input, environment: [:],
            pluginDirectory: root, workingDirectory: root
        )

        let result = try await HTTPPluginRunner(credentialStore: keychain).run(request)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.events, [
            .progress(.init(fraction: 0.5, message: "1/2", phase: "characterization",
                            completed: 1, total: 2, unit: "steps")),
            .result(status: "success", message: nil, clipboard: nil, artifacts: [])
        ])
        let taskPath = HTTPPluginTestFixture.taskID.uuidString.lowercased()
        let observations = try server.observations()
        XCTAssertEqual(observations.map { "\($0.method) \($0.path)" }, [
            "GET /openfinder/plugin/v1/health",
            "GET /openfinder/plugin/v1/capabilities",
            "POST /openfinder/plugin/v1/jobs",
            "GET /openfinder/plugin/v1/jobs/\(taskPath)/events",
            "GET /openfinder/plugin/v1/jobs/\(taskPath)/result"
        ])
        XCTAssertTrue(observations.allSatisfy(\.authorizationAccepted))
        XCTAssertEqual(observations[2].submittedTaskID, HTTPPluginTestFixture.taskID)
        XCTAssertEqual(observations[2].submittedSecretsEmpty, true)
        XCTAssertFalse(try Data(contentsOf: root.appendingPathComponent("observations.json"))
            .contains(Data(server.token.utf8)))
    }
}
