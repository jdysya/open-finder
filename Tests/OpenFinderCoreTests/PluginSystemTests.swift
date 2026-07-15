import Foundation
import XCTest
@testable import OpenFinderCore

final class PluginSystemTests: XCTestCase {
    func testDecodesManifestAndMatchesImageSelection() throws {
        let manifestData = Data(Self.manifestJSON.utf8)
        let manifest = try JSONDecoder.openFinder.decode(PluginManifest.self, from: manifestData)
        let action = try XCTUnwrap(manifest.actions.first)
        let png = FileItem(
            id: "local:/tmp/demo.png",
            name: "demo.png",
            location: .local(path: "/tmp/demo.png"),
            kind: .file,
            size: 10,
            modificationDate: nil,
            creationDate: nil,
            uti: "public.png",
            mimeType: "image/png",
            fileExtension: "png",
            isHidden: false,
            isReadable: true,
            isWritable: true
        )
        let text = FileItem(
            id: "local:/tmp/readme.txt",
            name: "readme.txt",
            location: .local(path: "/tmp/readme.txt"),
            kind: .file,
            size: 10,
            modificationDate: nil,
            creationDate: nil,
            uti: "public.plain-text",
            mimeType: "text/plain",
            fileExtension: "txt",
            isHidden: false,
            isReadable: true,
            isWritable: true
        )

        XCTAssertEqual(manifest.id, "dev.openfinder.plugins.image-upload.demo")
        XCTAssertTrue(PluginMatcher.action(action, matches: [png]))
        XCTAssertFalse(PluginMatcher.action(action, matches: [text]))
        XCTAssertFalse(PluginMatcher.action(action, matches: [png, png, png]))
    }

    func testSchemaOneManifestDecodesStringAndObjectRuntimesWithEntries() throws {
        let objectManifest = try JSONDecoder.openFinder.decode(
            PluginManifest.self,
            from: Data(Self.manifestJSON.utf8)
        )
        let stringJSON = Self.manifestJSON
            .replacingOccurrences(
                of: #""runtime": { "type": "python3", "minimumVersion": "3.9" }"#,
                with: #""runtime": "shell""#
            )
            .replacingOccurrences(of: #""entry": "upload.py""#, with: #""entry": "run.sh""#)
        let stringManifest = try JSONDecoder.openFinder.decode(
            PluginManifest.self,
            from: Data(stringJSON.utf8)
        )

        XCTAssertEqual(objectManifest.runtime, .python3(minimumVersion: "3.9"))
        XCTAssertEqual(objectManifest.entry, "upload.py")
        XCTAssertEqual(stringManifest.runtime, .shell)
        XCTAssertEqual(stringManifest.entry, "run.sh")
        XCTAssertEqual(objectManifest.execution, .process(runtime: .python3(minimumVersion: "3.9"), entry: "upload.py"))
        XCTAssertEqual(stringManifest.execution, .process(runtime: .shell, entry: "run.sh"))
        let encoded = try JSONEncoder.openFinder.encode(objectManifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["runtime"])
        XCTAssertEqual(object["entry"] as? String, "upload.py")
        XCTAssertNil(object["execution"])
    }

    func testParsesNDJSONOutputEvents() throws {
        let output = """
        {"type":"log","level":"info","message":"Uploading"}
        {"type":"progress","fraction":0.5,"message":"Halfway"}
        {"type":"result","status":"success","message":"Done","clipboard":"![demo](https://example.test/demo.png)"}
        """

        let events = try PluginOutputParser.parseNDJSON(output)

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .log(level: "info", message: "Uploading"))
        XCTAssertEqual(events[1], .progress(fraction: 0.5, message: "Halfway"))
        XCTAssertEqual(events[2].clipboardText, "![demo](https://example.test/demo.png)")
        XCTAssertFalse(events[2].isFailureResult)
        let failure = try PluginOutputParser.parseLine("{\"type\":\"result\",\"status\":\"failure\",\"message\":\"bad\"}")
        XCTAssertTrue(failure.isFailureResult)
    }

    func testResolvesPluginConfigurationFromSavedValuesAndDefaults() {
        let manifest = PluginManifest(
            schemaVersion: 1,
            id: "dev.openfinder.test.config",
            name: "Config",
            version: "0.1.0",
            description: nil,
            author: nil,
            runtime: .shell,
            entry: "run.sh",
            actions: [],
            permissions: .init(readFiles: "selected", writeFiles: "none", network: .init(), clipboardWrite: false, clipboardRead: false, keychainSecrets: ["apiToken"], remoteAccounts: false, runExternalCommands: false),
            configuration: [
                .init(key: "quality", type: "string", title: "Quality", defaultValue: "80"),
                .init(key: "endpoint", type: "url", title: "Endpoint")
            ]
        )

        let resolved = PluginConfigurationResolver.resolve(
            manifest: manifest,
            values: ["endpoint": "https://example.test/upload"],
            secretReferences: ["apiToken": "plugin.dev.openfinder.test.config.apiToken"]
        )

        XCTAssertEqual(resolved.config, ["quality": "80", "endpoint": "https://example.test/upload"])
        XCTAssertEqual(resolved.secrets["apiToken"]?.env, "plugin.dev.openfinder.test.config.apiToken")
    }

    func testRemoveQuarantinePluginOnlyMatchesSingleAppPackage() throws {
        let manifestURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ExamplePlugins/remove-quarantine.plugin/manifest.json")
        let manifest = try JSONDecoder.openFinder.decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
        let action = try XCTUnwrap(manifest.actions.first)
        let app = FileItem(
            id: "local:/Applications/Demo.app",
            name: "Demo.app",
            location: .local(path: "/Applications/Demo.app"),
            kind: .package,
            size: nil,
            modificationDate: nil,
            creationDate: nil,
            uti: "com.apple.application-bundle",
            mimeType: nil,
            fileExtension: "app",
            isHidden: false,
            isReadable: true,
            isWritable: true
        )
        let zip = FileItem(
            id: "local:/tmp/Demo.zip",
            name: "Demo.zip",
            location: .local(path: "/tmp/Demo.zip"),
            kind: .file,
            size: nil,
            modificationDate: nil,
            creationDate: nil,
            uti: "public.zip-archive",
            mimeType: "application/zip",
            fileExtension: "zip",
            isHidden: false,
            isReadable: true,
            isWritable: true
        )
        let appNamedFolder = FileItem(
            id: "local:/tmp/NotAnApplication.app",
            name: "NotAnApplication.app",
            location: .local(path: "/tmp/NotAnApplication.app"),
            kind: .directory,
            size: nil,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: nil,
            fileExtension: "app",
            isHidden: false,
            isReadable: true,
            isWritable: true
        )

        XCTAssertEqual(manifest.id, "dev.openfinder.plugins.remove-quarantine")
        XCTAssertTrue(PluginMatcher.action(action, matches: [app]))
        XCTAssertFalse(PluginMatcher.action(action, matches: [zip]))
        XCTAssertFalse(PluginMatcher.action(action, matches: [appNamedFolder]))
        XCTAssertFalse(PluginMatcher.action(action, matches: [app, app]))
    }

    func testRunsShellPluginWithStructuredInputAndEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderPluginTests-").appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginDir = root.appendingPathComponent("echo.plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let script = pluginDir.appendingPathComponent("run.sh")
        try """
        #!/bin/zsh
        INPUT=$(cat)
        echo '{"type":"log","level":"info","message":"received input"}'
        echo '{"type":"progress","fraction":1.0,"message":"complete"}'
        echo '{"type":"result","status":"success","message":"ok","clipboard":"copied"}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let manifest = PluginManifest(
            schemaVersion: 1,
            id: "dev.openfinder.test.echo",
            name: "Echo",
            version: "0.1.0",
            description: nil,
            author: "Tests",
            runtime: .shell,
            entry: "run.sh",
            actions: [.init(id: "echo", title: "Echo", category: "Test", selection: .init(minItems: 0, maxItems: nil, allowDirectories: true), match: nil, output: nil)],
            permissions: .none,
            configuration: []
        )
        let input = PluginInput(schemaVersion: 1, taskID: UUID(), actionID: "echo", app: .init(name: "OpenFinder", version: "0.1.0"), context: .init(activePane: "left", currentLocation: .local(path: "/tmp")), files: [], config: [:], secrets: [:], tempDirectory: root.path, outputDirectory: root.path)

        let result = try await ProcessPluginRunner().run(.init(manifest: manifest, action: manifest.actions[0], input: input, environment: [:], pluginDirectory: pluginDir, workingDirectory: pluginDir))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.events.last?.clipboardText, "copied")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    private static let manifestJSON = """
    {
      "schemaVersion": 1,
      "id": "dev.openfinder.plugins.image-upload.demo",
      "name": "Upload Image Demo",
      "version": "0.1.0",
      "description": "Uploads selected images.",
      "author": "OpenFinder",
      "runtime": { "type": "python3", "minimumVersion": "3.9" },
      "entry": "upload.py",
      "actions": [
        {
          "id": "upload-image",
          "title": "Upload Image",
          "category": "Upload",
          "selection": { "minItems": 1, "maxItems": 2, "allowDirectories": false },
          "match": {
            "extensions": ["png", "jpg", "jpeg"],
            "uttypes": ["public.image"],
            "mimePrefixes": ["image/"],
            "matchMode": "all"
          },
          "output": { "resultType": "markdownLinks", "canCopyToClipboard": true }
        }
      ],
      "permissions": {
        "readFiles": "selected",
        "writeFiles": "none",
        "network": { "required": true, "hosts": ["example.test"] },
        "clipboardWrite": true,
        "clipboardRead": false,
        "keychainSecrets": ["apiToken"],
        "remoteAccounts": false,
        "runExternalCommands": false
      },
      "configuration": []
    }
    """
}
