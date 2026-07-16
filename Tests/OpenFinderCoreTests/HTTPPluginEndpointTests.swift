import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginEndpointTests: XCTestCase {
    func testAcceptsOnlyCanonicalNumericLoopbackRoots() throws {
        XCTAssertEqual(try HTTPPluginEndpoint("http://127.0.0.1:8765").baseURL.absoluteString,
                       "http://127.0.0.1:8765/openfinder/plugin/v1")
        XCTAssertEqual(try HTTPPluginEndpoint("http://[::1]:65535/").baseURL.absoluteString,
                       "http://[::1]:65535/openfinder/plugin/v1")
    }

    func testRejectsNoncanonicalOrUnsafeEndpoints() {
        let invalid = [
            "https://127.0.0.1:8765", "http://localhost:8765", "http://127.1:8765",
            "http://2130706433:8765", "http://0x7f000001:8765",
            "http://127.0.0.1.:8765", "http://127%2e0%2e0%2e1:8765",
            "http://[0:0:0:0:0:0:0:1]:8765", "http://[::1%25lo0]:8765",
            "http://user@127.0.0.1:8765", "http://127.0.0.1",
            "http://127.0.0.1:0", "http://127.0.0.1:65536",
            "http://127.0.0.1:8765/path", "http://127.0.0.1:8765?x=1",
            "http://127.0.0.1:8765#x", " http://127.0.0.1:8765",
            "http://127.0.0.1:8765/../remote"
        ]
        for value in invalid {
            XCTAssertThrowsError(try HTTPPluginEndpoint(value), value)
        }
    }

    func testPreparesBearerThroughManifestReferenceAndScrubsTransportSecret() throws {
        let request = Self.request(tokenReference: "keychain.video.token")
        let prepared = try HTTPPluginEndpoint.prepare(request: request) { reference in
            XCTAssertEqual(reference, "keychain.video.token")
            return "fixture-token"
        }

        XCTAssertEqual(prepared.endpoint.baseURL.host, "127.0.0.1")
        XCTAssertEqual(prepared.bearerToken, "fixture-token")
        XCTAssertNil(prepared.input.secrets["serverToken"])
        XCTAssertEqual(prepared.input.secrets["modelToken"]?.env, "keychain.model")
        let body = String(decoding: try JSONEncoder.openFinder.encode(prepared.input), as: UTF8.self)
        XCTAssertFalse(body.contains("fixture-token"))
        XCTAssertFalse(body.contains("keychain.video.token"))
    }

    func testRejectsMissingMismatchedOrUnsafeCredential() {
        let cases: [(String?, String?)] = [
            (nil, "token"), ("wrong.reference", "token"),
            ("keychain.video.token", nil), ("keychain.video.token", ""),
            ("keychain.video.token", "line\nbreak"), ("keychain.video.token", "has space")
        ]
        for (reference, token) in cases {
            let request = Self.request(tokenReference: reference)
            XCTAssertThrowsError(try HTTPPluginEndpoint.prepare(request: request) { resolved in
                resolved == "keychain.video.token" ? token : nil
            })
        }
    }

    private static func request(tokenReference: String?) -> PluginRunRequest {
        let manifest = HTTPPluginTestFixture.manifest()
        var secrets = ["modelToken": PluginSecretReference(env: "keychain.model")]
        if let tokenReference { secrets["serverToken"] = .init(env: tokenReference) }
        let input = HTTPPluginTestFixture.input(config: ["serverURL": "http://127.0.0.1:8765"], secrets: secrets)
        return .init(manifest: manifest, action: manifest.actions[0], input: input, environment: [:],
                     pluginDirectory: URL(fileURLWithPath: "/tmp/plugin"), workingDirectory: URL(fileURLWithPath: "/tmp"))
    }
}

enum HTTPPluginTestFixture {
    static let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    static func manifest(execution: PluginExecution? = nil) -> PluginManifest {
        PluginManifest(schemaVersion: execution == nil ? 2 : schema(execution!), id: "dev.openfinder.plugins.video-analyzer",
                       name: "Video Analyzer", version: "0.1.0", description: nil, author: nil,
                       execution: execution ?? .http(protocolVersion: 1, endpointConfigurationKey: "serverURL", tokenSecretKey: "serverToken"),
                       actions: [.init(id: "analyze-video", title: "Analyze", category: nil,
                                       selection: .init(), match: nil, output: nil)],
                       permissions: .init(readFiles: "selected", writeFiles: "taskWorkspace", network: .init(),
                                          clipboardWrite: false, clipboardRead: false,
                                          keychainSecrets: ["serverToken"], remoteAccounts: false, runExternalCommands: false),
                       configuration: [.init(key: "serverURL", type: "string", title: "Server")])
    }

    static func input(config: [String: String] = [:], secrets: [String: PluginSecretReference] = [:]) -> PluginInput {
        .init(schemaVersion: 1, taskID: taskID, actionID: "analyze-video",
              app: .init(name: "OpenFinder", version: "0.1.0"),
              context: .init(activePane: "left", currentLocation: .local(path: "/tmp")), files: [],
              config: config, secrets: secrets, tempDirectory: "/tmp/task", outputDirectory: "/tmp/task/output")
    }

    private static func schema(_ execution: PluginExecution) -> Int {
        if case .process = execution { return 1 }
        return 2
    }
}
