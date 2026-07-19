import Foundation
import XCTest
@testable import OpenFinderCore

struct RealHTTPVideoAnalyzerWorkspace {
    let root: URL
    let taskRoot: URL
    let temp: URL
    let output: URL
    let store: URL
    let video: URL
    let gate: URL

    init(label: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderVideoAnalyzer-\(label)-\(UUID().uuidString)", isDirectory: true)
        taskRoot = root.appendingPathComponent("task", isDirectory: true)
        temp = taskRoot.appendingPathComponent("temp", isDirectory: true)
        output = taskRoot.appendingPathComponent("output", isDirectory: true)
        store = root.appendingPathComponent("store", isDirectory: true)
        video = root.appendingPathComponent("fixture.mp4")
        gate = root.appendingPathComponent("fixture.gate")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("deterministic-fixture-video".utf8).write(to: video)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func openGate() throws { try Data().write(to: gate, options: .atomic) }
}

final class RealHTTPEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PluginOutputEvent] = []

    func append(_ event: PluginOutputEvent) { lock.withLock { storage.append(event) } }
    func events() -> [PluginOutputEvent] { lock.withLock { storage } }

    func wait(
        timeout: TimeInterval = 5,
        until predicate: @escaping ([PluginOutputEvent]) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(events()) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RealHTTPVideoAnalyzerTestError.timedOut
    }
}

enum RealHTTPVideoAnalyzerTestError: Error { case timedOut }

enum RealHTTPVideoAnalyzerTestSupport {
    static let credentialReference = "tests.video-analyzer.token"

    static func repository() throws -> URL {
        guard let repository = try VideoAnalyzerFixtureProcess.repositoryIfAvailable() else {
            throw XCTSkip("Video Analyzer sibling repository or its .venv is absent.")
        }
        return repository
    }

    static func configuredRunner(
        fixture: VideoAnalyzerFixtureProcess,
        keychain: InMemoryKeychainStore = InMemoryKeychainStore()
    ) throws -> (HTTPPluginRunner, InMemoryKeychainStore) {
        try keychain.setSecret(fixture.token, for: credentialReference)
        return (HTTPPluginRunner(credentialStore: keychain), keychain)
    }

    static func request(
        taskID: UUID,
        fixture: VideoAnalyzerFixtureProcess,
        workspace: RealHTTPVideoAnalyzerWorkspace,
        config: [String: String] = [:],
        credentialReference: String = credentialReference,
        onEvent: (@Sendable (PluginOutputEvent) -> Void)? = nil
    ) -> PluginRunRequest {
        let manifest = HTTPPluginTestFixture.manifest()
        let item = FileItem(
            id: workspace.video.path, name: workspace.video.lastPathComponent,
            location: .local(path: workspace.video.path), kind: .file,
            size: Int64((try? Data(contentsOf: workspace.video).count) ?? 0),
            modificationDate: nil, creationDate: nil, uti: nil, mimeType: "video/mp4",
            fileExtension: "mp4", isHidden: false, isReadable: true, isWritable: true
        )
        var values = config
        values["serverURL"] = fixture.endpoint
        let input = PluginInput(
            schemaVersion: 1, taskID: taskID, actionID: manifest.actions[0].id,
            app: .init(name: "OpenFinder", version: "0.1.0"),
            context: .init(activePane: "left", currentLocation: .local(path: workspace.root.path)),
            files: [.init(item: item)], config: values,
            secrets: ["serverToken": .init(env: credentialReference)],
            tempDirectory: workspace.temp.path, outputDirectory: workspace.output.path
        )
        return .init(
            manifest: manifest, action: manifest.actions[0], input: input, environment: [:],
            pluginDirectory: workspace.root, workingDirectory: workspace.root, onEvent: onEvent
        )
    }

    static func waitForHistory(
        _ fixture: VideoAnalyzerFixtureProcess,
        timeout: TimeInterval = 5,
        until predicate: @escaping ([VideoAnalyzerFixtureHistoryRecord]) -> Bool
    ) async throws -> [VideoAnalyzerFixtureHistoryRecord] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let history = try fixture.history()
            if predicate(history) { return history }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RealHTTPVideoAnalyzerTestError.timedOut
    }

    static func assertClean(_ receipt: VideoAnalyzerFixtureCleanupReceipt, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(receipt.exited, "Fixture PID \(receipt.pid) did not exit", file: file, line: line)
        XCTAssertTrue(receipt.readinessRemoved, "Fixture readiness remained for PID \(receipt.pid)", file: file, line: line)
    }
}
