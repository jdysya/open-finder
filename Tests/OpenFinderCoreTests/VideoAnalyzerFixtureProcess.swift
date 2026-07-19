import Darwin
import Foundation

struct VideoAnalyzerFixtureOptions {
    var sseChunkBytes: Int? = nil
    var sseDisconnectAfterEvent: Int? = nil
    var disableSSE = false
    var lifetimeSeconds = 30
}

struct VideoAnalyzerFixtureLaunchOverride {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let readinessTimeout: TimeInterval
    let terminationGrace: TimeInterval
}

struct VideoAnalyzerFixtureHistoryRecord: Decodable {
    let kind: String
    let method: String?
    let path: String?
    let lastEventID: Int?
    let taskID: UUID?
    let config: [String: String]?
    let eventID: Int?
    let status: String?
    let chunkSizes: [Int]?
}

struct VideoAnalyzerFixtureCleanupReceipt {
    let pid: Int32
    let exited: Bool
    let readinessRemoved: Bool
}

enum VideoAnalyzerFixtureProcessError: Error, LocalizedError, Equatable {
    case invalidRepositoryOverride
    case requiredRepositoryMissing
    case pythonMissing
    case fixtureModuleMissing
    case staleReadinessFile
    case processExited(Int32)
    case readinessTimedOut
    case invalidReadiness

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryOverride: "OPENFINDER_VIDEO_ANALYZER_REPO does not name a usable repository."
        case .requiredRepositoryMissing: "Required Video Analyzer sibling repository is missing."
        case .pythonMissing: "Video Analyzer .venv/bin/python is missing or not executable."
        case .fixtureModuleMissing: "Video Analyzer test fixture module is missing."
        case .staleReadinessFile: "Fixture readiness path was not clean before launch."
        case .processExited(let status): "Video Analyzer fixture exited before readiness (status \(status))."
        case .readinessTimedOut: "Video Analyzer fixture readiness timed out."
        case .invalidReadiness: "Video Analyzer fixture readiness JSON is invalid."
        }
    }
}

final class VideoAnalyzerFixtureProcess: @unchecked Sendable {
    let endpoint: String
    let processIdentifier: Int32
    let readinessURL: URL
    let historyURL: URL
    let logURL: URL
    let token: String

    private let process: Process
    private let logHandle: FileHandle
    private let stateLock = NSLock()
    private let terminationGrace: TimeInterval
    private var didReap = false

    static func repositoryIfAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultRepository: URL? = nil
    ) throws -> URL? {
        let required = environment["OPENFINDER_REQUIRE_VIDEO_ANALYZER_E2E"] == "1"
        if let override = environment["OPENFINDER_VIDEO_ANALYZER_REPO"] {
            let repository = URL(fileURLWithPath: override).standardizedFileURL
            guard isDirectory(repository) else {
                throw VideoAnalyzerFixtureProcessError.invalidRepositoryOverride
            }
            guard hasPython(repository) else { throw VideoAnalyzerFixtureProcessError.pythonMissing }
            return try validateFixture(in: repository)
        }
        let openFinder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let repository = defaultRepository
            ?? openFinder.deletingLastPathComponent().appendingPathComponent("video-analyzer")
        guard isDirectory(repository) else {
            if required { throw VideoAnalyzerFixtureProcessError.requiredRepositoryMissing }
            return nil
        }
        guard hasPython(repository) else { throw VideoAnalyzerFixtureProcessError.pythonMissing }
        return try validateFixture(in: repository)
    }

    init(
        repository: URL,
        root: URL,
        options: VideoAnalyzerFixtureOptions = .init(),
        launchOverride: VideoAnalyzerFixtureLaunchOverride? = nil
    ) throws {
        readinessURL = root.appendingPathComponent("readiness.json")
        historyURL = root.appendingPathComponent("history.jsonl")
        logURL = root.appendingPathComponent("fixture.log")
        token = "fixture-\(UUID().uuidString.lowercased())"
        guard !FileManager.default.fileExists(atPath: readinessURL.path) else {
            throw VideoAnalyzerFixtureProcessError.staleReadinessFile
        }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: logURL)
        terminationGrace = launchOverride?.terminationGrace ?? 2
        let process = Process()
        process.currentDirectoryURL = repository
        process.executableURL = launchOverride?.executableURL
            ?? repository.appendingPathComponent(".venv/bin/python")
        var arguments = [
            "-m", "tests.openfinder_fixture_server",
            "--readiness-file", readinessURL.path,
            "--history-file", historyURL.path,
            "--heartbeat-seconds", "0.05",
            "--lifetime-seconds", String(options.lifetimeSeconds)
        ]
        if let bytes = options.sseChunkBytes { arguments += ["--sse-chunk-bytes", String(bytes)] }
        if let event = options.sseDisconnectAfterEvent {
            arguments += ["--sse-disconnect-after-event", String(event)]
        }
        if options.disableSSE { arguments.append("--disable-sse") }
        process.arguments = launchOverride?.arguments ?? arguments
        var environment = ProcessInfo.processInfo.environment
        launchOverride?.environment.forEach { environment[$0.key] = $0.value }
        environment["VIDEO_ANALYZER_OPENFINDER_TOKEN"] = token
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        self.process = process
        try process.run()
        processIdentifier = process.processIdentifier
        do {
            let readiness = try Self.waitForReadiness(
                at: readinessURL, process: process,
                timeout: launchOverride?.readinessTimeout ?? 8
            )
            guard readiness.pid == processIdentifier, (1 ... 65_535).contains(readiness.port) else {
                throw VideoAnalyzerFixtureProcessError.invalidReadiness
            }
            endpoint = "http://127.0.0.1:\(readiness.port)"
        } catch {
            _ = Self.terminate(
                process, pid: processIdentifier, force: false, grace: terminationGrace
            )
            try? logHandle.close()
            try? FileManager.default.removeItem(at: readinessURL)
            throw error
        }
    }

    var isRunning: Bool { process.isRunning }

    func history() throws -> [VideoAnalyzerFixtureHistoryRecord] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        return try String(contentsOf: historyURL, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(VideoAnalyzerFixtureHistoryRecord.self, from: Data($0.utf8))
        }
    }

    func stop() -> VideoAnalyzerFixtureCleanupReceipt { reap(force: false) }

    func crash() -> VideoAnalyzerFixtureCleanupReceipt { reap(force: true) }

    private func reap(force: Bool) -> VideoAnalyzerFixtureCleanupReceipt {
        stateLock.withLock {
            if !didReap {
                _ = Self.terminate(
                    process, pid: processIdentifier, force: force, grace: terminationGrace
                )
                try? logHandle.close()
                try? FileManager.default.removeItem(at: readinessURL)
                didReap = true
            }
            return .init(
                pid: processIdentifier,
                exited: !process.isRunning,
                readinessRemoved: !FileManager.default.fileExists(atPath: readinessURL.path)
            )
        }
    }

    private static func terminate(
        _ process: Process, pid: Int32, force: Bool, grace: TimeInterval
    ) -> Bool {
        if process.isRunning {
            if force { Darwin.kill(pid, SIGKILL) }
            else { process.terminate() }
        }
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { Darwin.kill(pid, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
        return !process.isRunning
    }

    private struct Readiness: Decodable { let pid: Int32; let port: Int }

    private static func waitForReadiness(
        at url: URL, process: Process, timeout: TimeInterval
    ) throws -> Readiness {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let data = try Data(contentsOf: url)
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          Set(object.keys) == ["pid", "port"] else {
                        throw VideoAnalyzerFixtureProcessError.invalidReadiness
                    }
                    return try JSONDecoder().decode(Readiness.self, from: data)
                } catch is VideoAnalyzerFixtureProcessError {
                    throw VideoAnalyzerFixtureProcessError.invalidReadiness
                } catch {
                    throw VideoAnalyzerFixtureProcessError.invalidReadiness
                }
            }
            if !process.isRunning { throw VideoAnalyzerFixtureProcessError.processExited(process.terminationStatus) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw VideoAnalyzerFixtureProcessError.readinessTimedOut
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func hasPython(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.appendingPathComponent(".venv/bin/python").path)
    }

    private static func validateFixture(in repository: URL) throws -> URL {
        let module = repository.appendingPathComponent("tests/openfinder_fixture_server.py")
        guard FileManager.default.fileExists(atPath: module.path) else {
            throw VideoAnalyzerFixtureProcessError.fixtureModuleMissing
        }
        return repository
    }
}
