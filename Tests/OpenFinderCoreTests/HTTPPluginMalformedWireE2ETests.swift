import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginMalformedWireE2ETests: XCTestCase {
    func testActualRunnerRejectsMalformedSSEBytesWithoutTokenDisclosure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPMalformedWire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try PortZeroHTTPCharacterizationServer(root: root, responseMode: .malformedSSE)
        defer { server.stop() }
        let keychain = InMemoryKeychainStore()
        try keychain.setSecret(server.token, for: "malformed-wire.token")

        var caught: Error?
        do {
            _ = try await HTTPPluginRunner(credentialStore: keychain).run(
                Self.request(root: root, endpoint: server.endpoint)
            )
        } catch {
            caught = error
        }

        XCTAssertEqual(caught as? ServerSentEventParserError, .invalidJSON)
        XCTAssertTrue(caught?.localizedDescription.contains("valid HTTP plugin event object") == true)
        XCTAssertFalse(caught?.localizedDescription.contains(server.token) == true)
        let observations = try server.observations()
        XCTAssertTrue(observations.contains { $0.path.hasSuffix("/events") })
        XCTAssertFalse(observations.contains { $0.path.hasSuffix("/result") })
        XCTAssertFalse(try Data(contentsOf: root.appendingPathComponent("observations.json"))
            .contains(Data(server.token.utf8)))
    }

    private static func request(root: URL, endpoint: String) throws -> PluginRunRequest {
        let manifest = HTTPPluginTestFixture.manifest()
        let input = PluginInput(
            schemaVersion: 1, taskID: UUID(), actionID: manifest.actions[0].id,
            app: .init(name: "OpenFinder", version: "0.1.0"),
            context: .init(activePane: "left", currentLocation: .local(path: root.path)),
            files: [], config: ["serverURL": endpoint],
            secrets: ["serverToken": .init(env: "malformed-wire.token")],
            tempDirectory: root.appendingPathComponent("temp").path,
            outputDirectory: root.appendingPathComponent("output").path
        )
        return .init(
            manifest: manifest, action: manifest.actions[0], input: input, environment: [:],
            pluginDirectory: root, workingDirectory: root
        )
    }
}
