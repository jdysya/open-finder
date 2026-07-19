import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginLocalCredentialTests: XCTestCase {
    func testRunnerResolvesLocalCredentialAndOmitsTokenAndReferenceFromRequestJSON() async throws {
        let keychain = FailingReadKeychainStore()
        let local = LocalPluginCredentialStore(pluginSecrets: [
            Self.pluginID: ["serverToken": "fixture-local-value"]
        ])
        let resolver = PluginCredentialResolver(keychainStore: keychain, localStore: local)
        let transport = ScriptedHTTPPluginTransport { request, _ in
            try Self.response(for: request)
        } stream: { _, _ in
            HTTPPluginResponseFixture.stream([
                HTTPPluginResponseFixture.frame(HTTPPluginResponseFixture.result, id: 2, type: "result")
            ])
        }
        let runner = HTTPPluginRunner(
            transport: transport, credentialResolver: resolver, sleep: { _ in }
        )

        let result = try await runner.run(Self.request())

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(keychain.readKeys, [])
        let requests = await transport.capturedDataRequests()
        let submission = try XCTUnwrap(requests.first { $0.httpMethod == "POST" })
        let body = String(decoding: try XCTUnwrap(submission.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("fixture-local-value"))
        XCTAssertFalse(body.contains("local-config.plugin"))
        XCTAssertFalse(body.contains("serverToken"))
    }

    func testProbeResolvesLocalCredentialAndUsesLocalConfigGuidance() async throws {
        let keychain = FailingReadKeychainStore()
        let local = LocalPluginCredentialStore(pluginSecrets: [
            Self.pluginID: ["serverToken": "fixture-local-value"]
        ])
        let resolver = PluginCredentialResolver(keychainStore: keychain, localStore: local)
        let transport = ScriptedHTTPPluginTransport { _, _ in
            HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.health)
        } stream: { _, _ in fatalError("unused") }
        let probe = HTTPPluginConnectionProbe(transport: transport, credentialResolver: resolver)

        let ready = await probe.check(
            manifest: Self.manifest,
            values: ["serverURL": "http://127.0.0.1:8765"],
            secretReferences: ["serverToken": Self.localReference]
        )
        let missing = await probe.check(
            manifest: Self.manifest,
            values: ["serverURL": "http://127.0.0.1:8765"],
            secretReferences: [:]
        )

        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(missing.issue, .missingToken)
        XCTAssertTrue(missing.guidance.contains("secured local config"))
        XCTAssertFalse(missing.guidance.contains("Keychain"))
        XCTAssertEqual(keychain.readKeys, [])
    }

    private static let pluginID = "dev.openfinder.plugins.video-analyzer"
    private static let localReference = PluginCredentialReference.localConfiguration(
        pluginID: pluginID, key: "serverToken"
    )

    private static let manifest = PluginManifest(
        schemaVersion: 2,
        id: pluginID,
        name: "Video Analyzer",
        version: "0.1.0",
        description: nil,
        author: nil,
        execution: .http(protocolVersion: 1, endpointConfigurationKey: "serverURL", tokenSecretKey: "serverToken"),
        actions: [HTTPPluginTestFixture.manifest().actions[0]],
        permissions: .init(
            readFiles: "selected",
            writeFiles: "taskOutput",
            network: .init(required: true, hosts: ["127.0.0.1"]),
            clipboardWrite: false,
            clipboardRead: false,
            keychainSecrets: [],
            remoteAccounts: false,
            runExternalCommands: false,
            localSecrets: ["serverToken"]
        ),
        configuration: [.init(key: "serverURL", type: "url", title: "Server URL", required: true)]
    )

    private static func request() -> PluginRunRequest {
        let input = HTTPPluginTestFixture.input(
            config: ["serverURL": "http://127.0.0.1:8765"],
            secrets: ["serverToken": .init(env: localReference)]
        )
        return .init(
            manifest: manifest,
            action: manifest.actions[0],
            input: input,
            environment: [:],
            pluginDirectory: URL(fileURLWithPath: "/tmp/plugin"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
    }

    private static func response(for request: URLRequest) throws -> HTTPPluginDataResponse {
        guard let path = request.url?.path else { throw URLError(.badURL) }
        if path.hasSuffix("/health") { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.health) }
        if path.hasSuffix("/capabilities") {
            return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.capabilities())
        }
        if request.httpMethod == "POST" {
            return HTTPPluginResponseFixture.data(
                HTTPPluginResponseFixture.snapshot(state: "queued", eventID: 0), status: 202
            )
        }
        if path.hasSuffix("/result") { return HTTPPluginResponseFixture.data(HTTPPluginResponseFixture.result) }
        throw URLError(.badServerResponse)
    }
}

private final class FailingReadKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String] = []

    var readKeys: [String] { lock.withLock { reads } }

    func secret(for key: String) throws -> String? {
        lock.withLock { reads.append(key) }
        throw OpenFinderError.operationFailed("Unexpected Keychain read")
    }

    func setSecret(_ secret: String, for key: String) throws {}
    func deleteSecret(for key: String) throws {}
}
