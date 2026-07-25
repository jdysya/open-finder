import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct PluginRunRequest: Sendable {
    public let manifest: PluginManifest
    public let action: PluginActionManifest
    public let input: PluginInput
    public let environment: [String: String]
    public let pluginDirectory: URL
    public let workingDirectory: URL
    public let onEvent: (@Sendable (PluginOutputEvent) -> Void)?
    public let onHTTPTranscript: (@Sendable (HTTPPluginTranscript) async -> Void)?

    public init(
        manifest: PluginManifest,
        action: PluginActionManifest,
        input: PluginInput,
        environment: [String: String],
        pluginDirectory: URL,
        workingDirectory: URL,
        onEvent: (@Sendable (PluginOutputEvent) -> Void)? = nil,
        onHTTPTranscript: (@Sendable (HTTPPluginTranscript) async -> Void)? = nil
    ) {
        self.manifest = manifest
        self.action = action
        self.input = input
        self.environment = environment
        self.pluginDirectory = pluginDirectory
        self.workingDirectory = workingDirectory
        self.onEvent = onEvent
        self.onHTTPTranscript = onHTTPTranscript
    }
}

public struct PluginRuntimePaths: Sendable, Hashable {
    public var shellPath: String
    public var python3Path: String?
    public var nodePath: String?

    public init(shellPath: String = "/bin/zsh", python3Path: String? = nil, nodePath: String? = nil) {
        self.shellPath = shellPath
        self.python3Path = python3Path
        self.nodePath = nodePath
    }
}

public struct PluginRunResult: Sendable {
    public let exitCode: Int32
    public let events: [PluginOutputEvent]
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, events: [PluginOutputEvent], stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.events = events
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol PluginRunner: Sendable {
    func run(_ request: PluginRunRequest) async throws -> PluginRunResult
    func cancel(taskID: UUID) async
}

public struct ProcessPluginRunner: PluginRunner {
    private let registry: ProcessRegistry
    private let runtimePaths: PluginRuntimePaths

    public init(registry: ProcessRegistry = ProcessRegistry(), runtimePaths: PluginRuntimePaths = PluginRuntimePaths()) {
        self.registry = registry
        self.runtimePaths = runtimePaths
    }

    public func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await Self.runProcess(request, registry: registry, runtimePaths: runtimePaths, box: box)
        } onCancel: {
            box.terminateThenKill()
        }
    }

    public func cancel(taskID: UUID) async {
        registry.terminate(taskID)
    }

    private static func runProcess(_ request: PluginRunRequest, registry: ProcessRegistry, runtimePaths: PluginRuntimePaths, box: ProcessBox) async throws -> PluginRunResult {
        let process = Process()
        let entryURL = request.pluginDirectory.appendingPathComponent(request.manifest.entry)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw OpenFinderError.itemNotFound(entryURL.path)
        }
        let command = Self.command(for: request.manifest.runtime, entryURL: entryURL, runtimePaths: runtimePaths)
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = request.workingDirectory
        process.environment = Self.sanitizedEnvironment(adding: request.environment)

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = PipeCollector(onEvent: request.onEvent)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.appendStdout(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.appendStderr(data)
        }

        box.set(process)
        registry.set(process, for: request.input.taskID)
        process.terminationHandler = { _ in
            box.clear(process)
            registry.remove(request.input.taskID, process: process)
        }

        try process.run()
        let inputData = try JSONEncoder.openFinder.encode(request.input)
        try stdin.fileHandleForWriting.write(contentsOf: inputData)
        try stdin.fileHandleForWriting.close()

        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        collector.appendStdout(stdout.fileHandleForReading.readDataToEndOfFile())
        collector.appendStderr(stderr.fileHandleForReading.readDataToEndOfFile())
        collector.finishStdout()
        if let error = collector.firstError { throw error }
        if Task.isCancelled { throw CancellationError() }
        let events = collector.events
        if process.terminationStatus == 0 {
            try ProcessPluginEventValidator.validate(events)
        }
        return PluginRunResult(exitCode: process.terminationStatus, events: events, stdout: collector.stdout, stderr: collector.stderr)
    }

    private static func command(for runtime: PluginRuntime, entryURL: URL, runtimePaths: PluginRuntimePaths) -> (executable: URL, arguments: [String]) {
        switch runtime {
        case .shell:
            return (URL(fileURLWithPath: runtimePaths.shellPath), [entryURL.path])
        case .python3:
            if let python3Path = runtimePaths.python3Path, !python3Path.isEmpty {
                return (URL(fileURLWithPath: python3Path), [entryURL.path])
            }
            return (URL(fileURLWithPath: "/usr/bin/env"), ["python3", entryURL.path])
        case .node:
            if let nodePath = runtimePaths.nodePath, !nodePath.isEmpty {
                return (URL(fileURLWithPath: nodePath), [entryURL.path])
            }
            return (URL(fileURLWithPath: "/usr/bin/env"), ["node", entryURL.path])
        }
    }

    private static func sanitizedEnvironment(adding additions: [String: String]) -> [String: String] {
        var environment: [String: String] = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8"
        ]
        for (key, value) in additions { environment[key] = value }
        return environment
    }
}

public final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]

    public init() {}

    fileprivate func set(_ process: Process, for taskID: UUID) {
        lock.lock(); defer { lock.unlock() }
        processes[taskID] = process
    }

    fileprivate func remove(_ taskID: UUID, process: Process) {
        lock.lock(); defer { lock.unlock() }
        if processes[taskID] === process { processes.removeValue(forKey: taskID) }
    }

    fileprivate func terminate(_ taskID: UUID) {
        lock.lock()
        let process = processes[taskID]
        lock.unlock()
        ProcessTerminator.terminateThenKill(process)
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var process: Process?

    func set(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
    }

    func clear(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        if self.process === process { self.process = nil }
    }

    func terminateThenKill() {
        lock.lock()
        let current = process
        lock.unlock()
        ProcessTerminator.terminateThenKill(current)
    }
}

private enum ProcessTerminator {
    static func terminateThenKill(_ process: Process?) {
        guard let process, process.isRunning else { return }
        #if canImport(Darwin)
        let killBox = ProcessKillBox(process)
        process.terminate()
        Task.detached { [killBox] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            killBox.killIfStillRunning()
        }
        #else
        process.terminate()
        #endif
    }
}

#if canImport(Darwin)
private final class ProcessKillBox: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func killIfStillRunning() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
#endif

private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutStorage = ""
    private var stderrStorage = ""
    private var stdoutLineBuffer = ""
    private var eventStorage: [PluginOutputEvent] = []
    private var errors: [Error] = []
    private let onEvent: (@Sendable (PluginOutputEvent) -> Void)?

    init(onEvent: (@Sendable (PluginOutputEvent) -> Void)?) {
        self.onEvent = onEvent
    }

    var stdout: String { locked { stdoutStorage } }
    var stderr: String { locked { stderrStorage } }
    var events: [PluginOutputEvent] { locked { eventStorage } }
    var firstError: Error? { locked { errors.first } }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        var emitted: [PluginOutputEvent] = []
        lock.lock()
        stdoutStorage += chunk
        stdoutLineBuffer += chunk
        while let newline = stdoutLineBuffer.firstIndex(where: \.isNewline) {
            let line = String(stdoutLineBuffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutLineBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let event = try PluginOutputParser.parseLine(line)
                eventStorage.append(event)
                emitted.append(event)
            } catch {
                errors.append(error)
            }
        }
        lock.unlock()
        emitted.forEach { onEvent?($0) }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        stderrStorage += chunk
    }

    func finishStdout() {
        var emitted: [PluginOutputEvent] = []
        lock.lock()
        let line = stdoutLineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        stdoutLineBuffer = ""
        if !line.isEmpty {
            do {
                let event = try PluginOutputParser.parseLine(line)
                eventStorage.append(event)
                emitted.append(event)
            } catch {
                errors.append(error)
            }
        }
        lock.unlock()
        emitted.forEach { onEvent?($0) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
