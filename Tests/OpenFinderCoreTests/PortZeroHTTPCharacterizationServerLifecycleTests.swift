import Darwin
import Foundation
import XCTest

final class PortZeroHTTPCharacterizationServerLifecycleTests: XCTestCase {
    func testStalledChildReadinessTimesOutAndReapsExactOwnedPID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPCharacterizationStall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pidURL = root.appendingPathComponent("owned.pid")
        let completion = CompletionProbe()
        DispatchQueue.global().async {
            let outcome: HTTPCharacterizationServerError?
            do {
                let server = try PortZeroHTTPCharacterizationServer(
                    root: root, program: Self.stalledProgram,
                    readinessTimeout: 0.1, terminationGrace: 0.05
                )
                server.stop()
                outcome = nil
            } catch let caught as HTTPCharacterizationServerError {
                outcome = caught
            } catch {
                outcome = .invalidReadiness
            }
            completion.finish(outcome)
        }

        try await Task.sleep(for: .milliseconds(600))
        let completedByDeadline = completion.isComplete
        let pid = try Self.readPID(pidURL)
        if !completedByDeadline { Darwin.kill(pid, SIGKILL) }
        let completionDeadline = Date().addingTimeInterval(1)
        while !completion.isComplete, Date() < completionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(completedByDeadline, "A stalled stdout pipe must not outlive the readiness deadline.")
        XCTAssertTrue(completion.isComplete, "Owned child teardown must complete promptly.")
        XCTAssertEqual(completion.error, .readinessTimedOut)
        Self.assertProcessGone(pid)
        try FileManager.default.removeItem(at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private static func readPID(_ url: URL) throws -> Int32 {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let raw = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(raw) { return pid }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw HTTPCharacterizationServerError.invalidReadiness
    }

    private static func assertProcessGone(
        _ pid: Int32, file: StaticString = #filePath, line: UInt = #line
    ) {
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "Owned PID \(pid) is still alive.", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }

    private static let stalledProgram = #"""
import os, pathlib, signal, time
root = pathlib.Path(os.environ["OPENFINDER_CHARACTERIZATION_OBSERVATIONS"]).parent
root.joinpath("owned.pid").write_text(str(os.getpid()), encoding="utf-8")
signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(30)
"""#
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false
    private var storedError: HTTPCharacterizationServerError?

    var isComplete: Bool { lock.withLock { complete } }
    var error: HTTPCharacterizationServerError? { lock.withLock { storedError } }

    func finish(_ error: HTTPCharacterizationServerError?) {
        lock.withLock {
            storedError = error
            complete = true
        }
    }
}
