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
              actions: [], permissions: .none, configuration: [])
    }

    private static func health(status: String = "ready", protocolVersion: Int = 1, checks: String = "[]") -> String {
        #"{"schemaVersion":1,"protocolVersion":\#(protocolVersion),"status":"\#(status)","pluginID":"dev.openfinder.plugins.video-analyzer","pluginVersion":"0.1.0","runtime":{"name":"Python","version":"3.12"},"checks":\#(checks)}"#
    }
}
