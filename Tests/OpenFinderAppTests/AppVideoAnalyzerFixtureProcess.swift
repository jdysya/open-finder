import Darwin
import Foundation

struct AppVideoAnalyzerFixtureRecord: Decodable {
    let kind: String
    let taskID: UUID?
    let config: [String: String]?
}

struct AppVideoAnalyzerFixtureLaunchOverride {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let readinessTimeout: TimeInterval
    let terminationGrace: TimeInterval
}

enum AppVideoAnalyzerFixtureError: Error, Equatable {
    case invalidRepositoryOverride
    case requiredRepositoryMissing
    case pythonMissing
    case fixtureModuleMissing
    case invalidReadiness
    case readinessTimeout
    case processExited(Int32)
}

final class AppVideoAnalyzerFixtureProcess: @unchecked Sendable {
    let endpoint: String
    let token: String
    let processIdentifier: Int32
    let historyURL: URL
    let readinessURL: URL

    private let process: Process
    private let output: FileHandle
    private let lock = NSLock()
    private let terminationGrace: TimeInterval
    private var reaped = false

    static func repositoryIfAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultRepository: URL? = nil
    ) throws -> URL? {
        let repository: URL
        let hasOverride: Bool
        if let override = environment["OPENFINDER_VIDEO_ANALYZER_REPO"] {
            repository = URL(fileURLWithPath: override).standardizedFileURL
            hasOverride = true
        } else {
            let openFinder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            repository = defaultRepository
                ?? openFinder.deletingLastPathComponent().appendingPathComponent("video-analyzer")
            hasOverride = false
        }
        let required = environment["OPENFINDER_REQUIRE_VIDEO_ANALYZER_E2E"] == "1"
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repository.path, isDirectory: &directory),
              directory.boolValue
        else {
            if hasOverride { throw AppVideoAnalyzerFixtureError.invalidRepositoryOverride }
            if required { throw AppVideoAnalyzerFixtureError.requiredRepositoryMissing }
            return nil
        }
        let python = repository.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw AppVideoAnalyzerFixtureError.pythonMissing
        }
        guard FileManager.default.fileExists(
            atPath: repository.appendingPathComponent("tests/openfinder_fixture_server.py").path
        ) else { throw AppVideoAnalyzerFixtureError.fixtureModuleMissing }
        return repository
    }

    init(
        repository: URL,
        root: URL,
        launchOverride: AppVideoAnalyzerFixtureLaunchOverride? = nil
    ) throws {
        token = "fixture-\(UUID().uuidString.lowercased())"
        historyURL = root.appendingPathComponent("app-history.jsonl")
        readinessURL = root.appendingPathComponent("app-readiness.json")
        let logURL = root.appendingPathComponent("app-fixture.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        output = try FileHandle(forWritingTo: logURL)
        terminationGrace = launchOverride?.terminationGrace ?? 2
        let process = Process()
        process.currentDirectoryURL = repository
        process.executableURL = launchOverride?.executableURL
            ?? repository.appendingPathComponent(".venv/bin/python")
        let fixtureArguments = [
            "-m", "tests.openfinder_fixture_server",
            "--readiness-file", readinessURL.path,
            "--history-file", historyURL.path,
            "--heartbeat-seconds", "0.05",
            "--lifetime-seconds", "30"
        ]
        process.arguments = launchOverride?.arguments ?? fixtureArguments
        var environment = ProcessInfo.processInfo.environment
        launchOverride?.environment.forEach { environment[$0.key] = $0.value }
        environment["VIDEO_ANALYZER_OPENFINDER_TOKEN"] = token
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        self.process = process
        try process.run()
        processIdentifier = process.processIdentifier
        do {
            let ready = try Self.waitForReadiness(
                readinessURL, process: process,
                timeout: launchOverride?.readinessTimeout ?? 8
            )
            guard ready.pid == processIdentifier, (1 ... 65_535).contains(ready.port) else {
                throw AppVideoAnalyzerFixtureError.invalidReadiness
            }
            endpoint = "http://127.0.0.1:\(ready.port)"
        } catch {
            _ = Self.terminate(process, pid: processIdentifier, grace: terminationGrace)
            try? output.close()
            try? FileManager.default.removeItem(at: readinessURL)
            throw error
        }
    }

    func history() throws -> [AppVideoAnalyzerFixtureRecord] {
        try String(contentsOf: historyURL, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(AppVideoAnalyzerFixtureRecord.self, from: Data($0.utf8))
        }
    }

    func stop() -> Bool {
        lock.withLock {
            guard !reaped else { return !process.isRunning }
            let exited = Self.terminate(
                process, pid: processIdentifier, grace: terminationGrace
            )
            try? output.close()
            try? FileManager.default.removeItem(at: readinessURL)
            reaped = true
            return exited
        }
    }

    private static func terminate(
        _ process: Process, pid: Int32, grace: TimeInterval
    ) -> Bool {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { Darwin.kill(pid, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
        return !process.isRunning
    }

    private struct Readiness: Decodable { let pid: Int32; let port: Int }

    private static func waitForReadiness(
        _ url: URL, process: Process, timeout: TimeInterval
    ) throws -> Readiness {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let data = try Data(contentsOf: url)
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          Set(object.keys) == ["pid", "port"] else {
                        throw AppVideoAnalyzerFixtureError.invalidReadiness
                    }
                    return try JSONDecoder().decode(Readiness.self, from: data)
                } catch is AppVideoAnalyzerFixtureError {
                    throw AppVideoAnalyzerFixtureError.invalidReadiness
                } catch {
                    throw AppVideoAnalyzerFixtureError.invalidReadiness
                }
            }
            if !process.isRunning { throw AppVideoAnalyzerFixtureError.processExited(process.terminationStatus) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw AppVideoAnalyzerFixtureError.readinessTimeout
    }
}
