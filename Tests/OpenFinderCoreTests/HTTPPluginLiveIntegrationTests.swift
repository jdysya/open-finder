import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginLiveIntegrationTests: XCTestCase {
    func testRealPythonFixtureServerWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["OPENFINDER_LIVE_ENDPOINT"],
              let token = environment["OPENFINDER_LIVE_TOKEN"] else {
            throw XCTSkip("Set OPENFINDER_LIVE_ENDPOINT and OPENFINDER_LIVE_TOKEN for the manual cross-repo check.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderHTTP-Live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("fixture.mp4")
        try Data("fixture".utf8).write(to: video)
        let item = FileItem(
            id: video.path, name: video.lastPathComponent, location: .local(path: video.path), kind: .file,
            size: 7, modificationDate: nil, creationDate: nil, uti: nil, mimeType: "video/mp4",
            fileExtension: "mp4", isHidden: false, isReadable: true, isWritable: true
        )
        let manifest = HTTPPluginTestFixture.manifest()
        let input = PluginInput(
            schemaVersion: 1, taskID: HTTPPluginTestFixture.taskID, actionID: manifest.actions[0].id,
            app: .init(name: "OpenFinder", version: "0.1.0"),
            context: .init(activePane: "left", currentLocation: .local(path: root.path)),
            files: [.init(item: item)], config: ["serverURL": endpoint],
            secrets: ["serverToken": .init(env: "manual.video.token")],
            tempDirectory: root.appendingPathComponent("temp").path,
            outputDirectory: root.appendingPathComponent("output").path
        )
        let keychain = InMemoryKeychainStore()
        try keychain.setSecret(token, for: "manual.video.token")
        let request = PluginRunRequest(
            manifest: manifest, action: manifest.actions[0], input: input, environment: [:],
            pluginDirectory: root, workingDirectory: root
        )

        let result = try await HTTPPluginRunner(credentialStore: keychain).run(request)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.events.contains { if case .progress = $0 { true } else { false } })
        XCTAssertEqual(result.events.last?.resultStatus, "success")
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
    }
}
