import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginConnectionProbeTests: XCTestCase {
    func testMissingEndpointAndTokenAreDistinct() async {
        let missingEndpoint = await probe().check(
            manifest: manifest(), values: [:], secretReferences: [:]
        )
        XCTAssertEqual(missingEndpoint.state, .unavailable)
        XCTAssertEqual(missingEndpoint.issue, .missingEndpoint)

        let missingToken = await probe().check(
            manifest: manifest(), values: ["serverURL": endpoint], secretReferences: [:]
        )
        XCTAssertEqual(missingToken.issue, .missingToken)
        XCTAssertTrue(missingToken.guidance.contains("token"))
    }

    func testReadyAndDegradedHealthExposeVersionsAndChecks() async {
        let ready = await probe(response: Self.health(status: "ready", checks: "[]")).check(
            manifest: manifest(), values: ["serverURL": endpoint], secretReferences: references
        )
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.protocolVersion, 1)
        XCTAssertEqual(ready.pluginVersion, "0.1.0")
        XCTAssertEqual(ready.runtime?.name, "Python")

        let checks = #"[{"id":"models","status":"warning","message":"Model warming","remediation":"Wait for warm-up"}]"#
        let degraded = await probe(response: Self.health(status: "degraded", checks: checks)).check(
            manifest: manifest(), values: ["serverURL": endpoint], secretReferences: references
        )
        XCTAssertEqual(degraded.state, .degraded)
        XCTAssertEqual(degraded.checks.first?.id, "models")
        XCTAssertEqual(degraded.checks.first?.remediation, "Wait for warm-up")
    }

    func testServerHealthFieldsCannotPlaceTokenInConnectionState() async {
        let checks = #"[{"id":"fixture-token","status":"warning","message":"fixture-token","remediation":"fixture-token"}]"#
        let response = #"{"schemaVersion":1,"protocolVersion":1,"status":"degraded","pluginID":"dev.openfinder.plugins.video-analyzer","pluginVersion":"fixture-token","runtime":{"name":"fixture-token","version":"fixture-token"},"checks":\#(checks)}"#

        let status = await probe(response: response).check(
            manifest: manifest(), values: ["serverURL": endpoint], secretReferences: references
        )

        XCTAssertFalse(String(describing: status).contains("fixture-token"))
    }

    func testWrongTokenStoppedServerAndIncompatibleProtocolAreActionableAndRedacted() async {
        let wrongToken = await probe(response: #"{"schemaVersion":1,"code":"unauthorized","message":"bad fixture-token","retryable":false}"#, status: 401).check(
            manifest: manifest(), values: ["serverURL": endpoint], secretReferences: references
        )
        XCTAssertEqual(wrongToken.issue, .authenticationFailed)
        XCTAssertFalse(String(describing: wrongToken).contains("fixture-token"))

        let stopped = await probe(error: URLError(.cannotConnectToHost)).check(
            manifest: manifest(), values: ["serverURL": endpoint], secretReferences: references
        )
        XCTAssertEqual(stopped.issue, .serverUnavailable)
        XCTAssertTrue(stopped.guidance.lowercased().contains("start"))

        let incompatible = await probe(response: Self.health(protocolVersion: 2)).check(
            manifest: manifest(), values: ["serverURL": endpoint], secretReferences: references
        )
        XCTAssertEqual(incompatible.issue, .incompatibleProtocol)
    }

    func testTruePluginMismatchAndHTTP426PreserveExistingMappings() async {
        let otherPlugin = Self.health().replacingOccurrences(
            of: "dev.openfinder.plugins.video-analyzer", with: "dev.openfinder.plugins.other"
        )
        let incompatible = await probe(response: otherPlugin).check(
            manifest: manifest(), values: ["serverURL": endpoint], secretReferences: references
        )
        XCTAssertEqual(incompatible.issue, .incompatiblePlugin)

        let unsupportedProtocol = await probe(
            response: #"{"schemaVersion":1,"code":"unsupported_protocol","message":"bad fixture-token","retryable":false}"#,
            status: 426
        ).check(manifest: manifest(), values: ["serverURL": endpoint], secretReferences: references)
        XCTAssertEqual(unsupportedProtocol.issue, .serverUnavailable)
        XCTAssertTrue(unsupportedProtocol.guidance.contains("426"))
        XCTAssertTrue(unsupportedProtocol.guidance.contains("unsupported_protocol"))
        XCTAssertFalse(String(describing: unsupportedProtocol).contains("fixture-token"))
    }

    func testPublicMinimalHealthFollowedByCapabilities401ReturnsAuthenticationFailedNotIncompatiblePlugin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPPluginWrongToken-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = try PortZeroHTTPCharacterizationServer(root: root, program: Self.publicHealthProgram)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let suppliedBearer = "wrong-fixture-token"
        let probe = HTTPPluginConnectionProbe(
            transport: URLSessionHTTPPluginTransport(),
            credentialResolver: { _ in suppliedBearer }
        )

        let status = await probe.check(
            manifest: manifest(), values: ["serverURL": server.endpoint], secretReferences: references
        )

        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(
            status.issue, .authenticationFailed,
            "Public minimal health must reach authenticated capabilities, not report an incompatible plugin."
        )
        XCTAssertEqual(
            status.guidance,
            "The server rejected the token. Save the matching token in the secured local config and retry."
        )
        XCTAssertFalse(String(describing: status).contains(suppliedBearer))
        XCTAssertEqual(try server.observations().map(\.path), [
            "/openfinder/plugin/v1/health",
            "/openfinder/plugin/v1/capabilities"
        ])
    }

    func testRealAnalyzerWrongAndCorrectBearersToggleAuthenticationFailureToReady() async throws {
        let repository = try RealHTTPVideoAnalyzerTestSupport.repository()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPPluginProbeRealAnalyzer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try VideoAnalyzerFixtureProcess(repository: repository, root: root)
        defer {
            RealHTTPVideoAnalyzerTestSupport.assertClean(fixture.stop())
            try? FileManager.default.removeItem(at: root)
        }
        let wrongBearer = "wrong-\(UUID().uuidString.lowercased())"
        let wrongResolver = PluginCredentialResolver(
            keychainStore: InMemoryKeychainStore(),
            localStore: LocalPluginCredentialStore(pluginSecrets: [
                "dev.openfinder.plugins.video-analyzer": ["serverToken": wrongBearer]
            ])
        )
        let correctResolver = PluginCredentialResolver(
            keychainStore: InMemoryKeychainStore(),
            localStore: LocalPluginCredentialStore(pluginSecrets: [
                "dev.openfinder.plugins.video-analyzer": ["serverToken": fixture.token]
            ])
        )
        let wrongProbe = HTTPPluginConnectionProbe(
            credentialResolver: wrongResolver
        )
        let correctProbe = HTTPPluginConnectionProbe(
            credentialResolver: correctResolver
        )
        let localReferences = [
            "serverToken": PluginCredentialReference.localConfiguration(
                pluginID: "dev.openfinder.plugins.video-analyzer", key: "serverToken"
            )
        ]

        let wrong = await wrongProbe.check(
            manifest: manifest(), values: ["serverURL": fixture.endpoint], secretReferences: localReferences
        )
        let correct = await correctProbe.check(
            manifest: manifest(), values: ["serverURL": fixture.endpoint], secretReferences: localReferences
        )

        XCTAssertEqual(wrong.issue, .authenticationFailed)
        XCTAssertEqual(correct.state, .ready)
        XCTAssertEqual(correct.pluginID, "dev.openfinder.plugins.video-analyzer")
        XCTAssertFalse(String(describing: [wrong, correct]).contains(wrongBearer))
        XCTAssertFalse(String(describing: [wrong, correct]).contains(fixture.token))
        XCTAssertEqual(try fixture.history().compactMap(\.path), [
            "/openfinder/plugin/v1/health",
            "/openfinder/plugin/v1/capabilities",
            "/openfinder/plugin/v1/health"
        ])
    }

    private let endpoint = "http://127.0.0.1:8765"
    private let references = ["serverToken": "fixture-key"]

    private func probe(response: String? = nil, status: Int = 200) -> HTTPPluginConnectionProbe {
        let transport = ScriptedHTTPPluginTransport(data: { _, _ in
            HTTPPluginResponseFixture.data(response ?? Self.health(), status: status)
        }, stream: { _, _ in fatalError("unused") })
        return HTTPPluginConnectionProbe(
            transport: transport,
            credentialResolver: { $0 == "fixture-key" ? "fixture-token" : nil }
        )
    }

    private func probe(error: Error) -> HTTPPluginConnectionProbe {
        let transport = ScriptedHTTPPluginTransport(data: { _, _ in throw error }, stream: { _, _ in throw error })
        return HTTPPluginConnectionProbe(transport: transport, credentialResolver: { _ in "fixture-token" })
    }

    private func manifest() -> PluginManifest {
        .init(schemaVersion: 2, id: "dev.openfinder.plugins.video-analyzer", name: "Analyzer", version: "0.1.0",
              description: nil, author: nil,
              execution: .http(protocolVersion: 1, endpointConfigurationKey: "serverURL", tokenSecretKey: "serverToken"),
              actions: [],
              permissions: .init(
                readFiles: "selected", writeFiles: "taskOutput",
                network: .init(required: true, hosts: ["127.0.0.1"]),
                clipboardWrite: false, clipboardRead: false, keychainSecrets: [],
                remoteAccounts: false, runExternalCommands: false,
                localSecrets: ["serverToken"]
              ),
              configuration: [.init(key: "serverURL", type: "url", title: "Server URL")])
    }

    private static func health(status: String = "ready", protocolVersion: Int = 1, checks: String = "[]") -> String {
        #"{"schemaVersion":1,"protocolVersion":\#(protocolVersion),"status":"\#(status)","pluginID":"dev.openfinder.plugins.video-analyzer","pluginVersion":"0.1.0","runtime":{"name":"Python","version":"3.12"},"checks":\#(checks)}"#
    }

    private static let publicHealthProgram = #"""
import http.server, json, os

TOKEN = os.environ["OPENFINDER_CHARACTERIZATION_TOKEN"]
OBSERVATIONS = os.environ["OPENFINDER_CHARACTERIZATION_OBSERVATIONS"]
records = []

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass
    def send_json(self, value, status=200):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("OpenFinder-Plugin-Protocol", "1")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        records.append({"method": "GET", "path": self.path,
                        "authorizationAccepted": self.headers.get("Authorization") == "Bearer " + TOKEN})
        with open(OBSERVATIONS, "w", encoding="utf-8") as handle:
            json.dump(records, handle)
        if self.path.endswith("/health"):
            return self.send_json({"schemaVersion":1,"protocolVersion":1,"status":"ready"})
        self.send_json({"schemaVersion":1,"code":"unauthorized",
                        "message":"denied wrong-fixture-token","retryable":False}, 401)

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print("READY " + str(server.server_address[1]), flush=True)
server.serve_forever()
"""#
}
