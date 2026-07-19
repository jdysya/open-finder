import Foundation
import XCTest
@testable import OpenFinderCore

final class VideoAnalyzerPluginTests: XCTestCase {
    func testSourceManifestUsesLocalHTTPExecution() throws {
        // Given
        let manifestURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ExamplePlugins/video-analyzer.plugin/manifest.json")
        let data = try Data(contentsOf: manifestURL)

        // When
        let manifest = try JSONDecoder.openFinder.decode(PluginManifest.self, from: data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Then
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.id, "dev.openfinder.plugins.video-analyzer")
        XCTAssertEqual(manifest.version, "0.1.0")
        XCTAssertEqual(manifest.actions.map(\.id), ["analyze-video"])
        XCTAssertEqual(manifest.execution, .http(
            protocolVersion: 1,
            endpointConfigurationKey: "serverURL",
            tokenSecretKey: "serverToken"
        ))
        XCTAssertEqual(manifest.configuration.map(\.key), ["serverURL", "useJoyTag"])
        XCTAssertEqual(manifest.configuration.first { $0.key == "serverURL" }?.defaultValue, "http://127.0.0.1:8765")
        XCTAssertEqual(manifest.configuration.first { $0.key == "useJoyTag" }?.defaultValue, "true")
        XCTAssertTrue(manifest.permissions.network.required)
        XCTAssertEqual(Set(manifest.permissions.network.hosts), ["127.0.0.1", "::1"])
        XCTAssertEqual(manifest.permissions.localSecrets, ["serverToken"])
        XCTAssertEqual(manifest.permissions.keychainSecrets, [])
        XCTAssertFalse(manifest.permissions.runExternalCommands)
        XCTAssertNil(object["runtime"])
        XCTAssertNil(object["entry"])
    }

    func testHTTPManifestDecodesAndRoundTripsExecutionDescriptor() throws {
        let manifest = try JSONDecoder.openFinder.decode(
            PluginManifest.self,
            from: Data(Self.httpManifestJSON.utf8)
        )

        XCTAssertEqual(manifest.execution, .http(
            protocolVersion: 1,
            endpointConfigurationKey: "serverURL",
            tokenSecretKey: "serverToken"
        ))

        let encoded = try JSONEncoder.openFinder.encode(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["runtime"])
        XCTAssertNil(object["entry"])
        XCTAssertEqual(try JSONDecoder.openFinder.decode(PluginManifest.self, from: encoded), manifest)
    }

    func testLegacyHTTPManifestMayStillDeclareItsTokenInKeychain() throws {
        let legacyJSON = Self.httpManifestJSON
            .replacingOccurrences(of: "\"localSecrets\": [\"serverToken\"]", with: "\"localSecrets\": []")
            .replacingOccurrences(of: "\"keychainSecrets\": []", with: "\"keychainSecrets\": [\"serverToken\"]")

        let manifest = try JSONDecoder.openFinder.decode(PluginManifest.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(manifest.permissions.localSecrets, [])
        XCTAssertEqual(manifest.permissions.keychainSecrets, ["serverToken"])
    }

    func testRejectsInvalidHTTPManifestMatrix() throws {
        let invalidManifests = [
            (
                "mixed legacy and execution fields",
                Self.httpManifestJSON.replacingOccurrences(
                    of: "\"execution\": {",
                    with: "\"runtime\": \"shell\",\n  \"entry\": \"run.sh\",\n  \"execution\": {"
                )
            ),
            (
                "unsupported manifest schema",
                Self.httpManifestJSON.replacingOccurrences(of: "\"schemaVersion\": 2", with: "\"schemaVersion\": 3")
            ),
            (
                "unsupported HTTP protocol",
                Self.httpManifestJSON.replacingOccurrences(of: "\"protocolVersion\": 1", with: "\"protocolVersion\": 2")
            ),
            (
                "empty endpoint configuration key",
                Self.httpManifestJSON.replacingOccurrences(
                    of: "\"endpointConfigurationKey\": \"serverURL\"",
                    with: "\"endpointConfigurationKey\": \"\""
                )
            ),
            (
                "empty token secret key",
                Self.httpManifestJSON.replacingOccurrences(
                    of: "\"tokenSecretKey\": \"serverToken\"",
                    with: "\"tokenSecretKey\": \"\""
                )
            ),
            (
                "missing endpoint configuration field",
                Self.httpManifestJSON.replacingOccurrences(
                    of: "\"key\": \"serverURL\"",
                    with: "\"key\": \"differentURL\""
                )
            ),
            (
                "missing token permission",
                Self.httpManifestJSON.replacingOccurrences(
                    of: "\"localSecrets\": [\"serverToken\"]",
                    with: "\"localSecrets\": []"
                )
            ),
            (
                "ambiguous local and keychain token permission",
                Self.httpManifestJSON.replacingOccurrences(
                    of: "\"keychainSecrets\": []",
                    with: "\"keychainSecrets\": [\"serverToken\"]"
                )
            )
        ]

        for (name, json) in invalidManifests {
            XCTAssertNotEqual(json, Self.httpManifestJSON, name)
            XCTAssertThrowsError(
                try JSONDecoder.openFinder.decode(PluginManifest.self, from: Data(json.utf8)),
                name
            ) { error in
                guard let openFinderError = error as? OpenFinderError,
                      case .invalidPluginManifest = openFinderError else {
                    return XCTFail("Expected invalidPluginManifest for \(name), got \(error)")
                }
            }
        }
    }

    func testRegistryReportsInvalidHTTPManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderInvalidHTTPManifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginDirectory = root.appendingPathComponent("invalid.plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        let invalidManifest = Self.httpManifestJSON.replacingOccurrences(
            of: "\"localSecrets\": [\"serverToken\"]",
            with: "\"localSecrets\": []"
        )
        try invalidManifest.write(
            to: pluginDirectory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try PluginRegistry().scan(directory: root)) { error in
            guard let openFinderError = error as? OpenFinderError,
                  case .invalidPluginManifest = openFinderError else {
                return XCTFail("Expected invalidPluginManifest, got \(error)")
            }
        }
    }

    func testManifestMatchesVideoFilesAndRejectsTextFiles() throws {
        let manifestURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ExamplePlugins/video-analyzer.plugin/manifest.json")
        let manifest = try JSONDecoder.openFinder.decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
        let action = try XCTUnwrap(manifest.actions.single)

        XCTAssertEqual(manifest.id, "dev.openfinder.plugins.video-analyzer")
        XCTAssertTrue(PluginMatcher.action(action, matches: [Self.item(name: "demo.mp4", extension: "mp4", mimeType: "video/mp4")]))
        XCTAssertTrue(PluginMatcher.action(action, matches: [Self.item(name: "demo.mkv", extension: "mkv", mimeType: "video/x-matroska")]))
        XCTAssertFalse(PluginMatcher.action(action, matches: [Self.item(name: "notes.txt", extension: "txt", mimeType: "text/plain")]))
    }

    func testReadmesStateShippedWrongTokenAndHTTP426ConnectionMappings() throws {
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let readme = repository.appendingPathComponent("ExamplePlugins/video-analyzer.plugin/README.md")
        let requiredFacts = [
            "A public minimal `/health` is followed by authenticated `/capabilities`; HTTP 401/403 maps to `PluginConnectionIssue.authenticationFailed`.",
            "HTTP 426 `unsupported_protocol` maps to `PluginConnectionIssue.serverUnavailable`, with the status and code retained in guidance.",
            "OpenFinder stores `serverToken` in its secured local Application Support `config.json`, not in macOS Keychain.",
            "The file is atomically maintained with mode `0600`.",
            "The token remains outside generic plugin configuration and HTTP request JSON.",
            "OpenFinder keeps the old Keychain item after a successful local migration."
        ]

        let contents = try String(contentsOf: readme, encoding: .utf8)
        for fact in requiredFacts {
            XCTAssertTrue(contents.contains(fact), "\(readme.path) is missing shipped fact: \(fact)")
        }
    }

    private static func item(name: String, extension fileExtension: String, mimeType: String) -> FileItem {
        .init(
            id: "local:/tmp/\(name)",
            name: name,
            location: .local(path: "/tmp/\(name)"),
            kind: .file,
            size: 1,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: mimeType,
            fileExtension: fileExtension,
            isHidden: false,
            isReadable: true,
            isWritable: true
        )
    }

    private static let httpManifestJSON = """
    {
      "schemaVersion": 2,
      "id": "dev.openfinder.plugins.video-analyzer.http",
      "name": "Video Analyzer HTTP",
      "version": "1.0.0",
      "execution": {
        "type": "http",
        "protocolVersion": 1,
        "endpointConfigurationKey": "serverURL",
        "tokenSecretKey": "serverToken"
      },
      "actions": [],
      "permissions": {
        "readFiles": "selected",
        "writeFiles": "taskOutput",
        "network": { "required": true, "hosts": ["127.0.0.1", "::1"] },
        "clipboardWrite": false,
        "clipboardRead": false,
        "localSecrets": ["serverToken"],
        "keychainSecrets": [],
        "remoteAccounts": false,
        "runExternalCommands": false
      },
      "configuration": [
        { "key": "serverURL", "type": "url", "title": "Server URL", "required": true }
      ]
    }
    """
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
