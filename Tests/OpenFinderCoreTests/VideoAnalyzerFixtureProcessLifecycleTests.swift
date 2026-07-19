import Darwin
import Foundation
import XCTest

final class VideoAnalyzerFixtureProcessLifecycleTests: XCTestCase {
    func testDefaultModeMaySkipAnAbsentRepository() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("OptionalVideoAnalyzer-\(UUID().uuidString)")
        XCTAssertNil(try VideoAnalyzerFixtureProcess.repositoryIfAvailable(
            environment: [:], defaultRepository: missing
        ))
    }

    func testRequiredModeFailsInsteadOfSkippingMissingRepository() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingVideoAnalyzer-\(UUID().uuidString)")
        XCTAssertThrowsError(try VideoAnalyzerFixtureProcess.repositoryIfAvailable(
            environment: ["OPENFINDER_REQUIRE_VIDEO_ANALYZER_E2E": "1"],
            defaultRepository: missing
        )) { error in
            XCTAssertEqual(error as? VideoAnalyzerFixtureProcessError, .requiredRepositoryMissing)
        }
    }

    func testIncompleteCheckoutFailsInsteadOfSkippingMissingPython() throws {
        let root = try Self.makeRoot("incomplete")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try VideoAnalyzerFixtureProcess.repositoryIfAvailable(
            environment: [:], defaultRepository: root
        )) { error in
            XCTAssertEqual(error as? VideoAnalyzerFixtureProcessError, .pythonMissing)
        }
    }

    func testReadinessTimeoutReapsOwnedPIDAndRemovesRoot() throws {
        try assertLaunchFailure(mode: "timeout", expected: .readinessTimedOut)
    }

    func testMalformedReadinessReapsOwnedPIDAndRemovesRoot() throws {
        try assertLaunchFailure(mode: "malformed", expected: .invalidReadiness)
    }

    func testMismatchedPIDReadinessReapsOwnedPIDAndRemovesRoot() throws {
        try assertLaunchFailure(mode: "mismatched", expected: .invalidReadiness)
    }

    private func assertLaunchFailure(
        mode: String,
        expected: VideoAnalyzerFixtureProcessError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let root = try Self.makeRoot(mode)
        let readiness = root.appendingPathComponent("readiness.json")
        let pidURL = root.appendingPathComponent("owned.pid")
        let launch = VideoAnalyzerFixtureLaunchOverride(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", Self.lifecycleProgram],
            environment: [
                "OPENFINDER_LIFECYCLE_MODE": mode,
                "OPENFINDER_LIFECYCLE_READINESS": readiness.path,
                "OPENFINDER_LIFECYCLE_PID": pidURL.path
            ],
            readinessTimeout: 0.1,
            terminationGrace: 0.05
        )
        let started = Date()
        var caught: Error?
        do {
            let fixture = try VideoAnalyzerFixtureProcess(
                repository: root, root: root, launchOverride: launch
            )
            _ = fixture.stop()
            XCTFail("Expected \(mode) readiness failure", file: file, line: line)
        } catch {
            caught = error
        }
        let elapsed = Date().timeIntervalSince(started)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidURL, encoding: .utf8)))

        XCTAssertEqual(caught as? VideoAnalyzerFixtureProcessError, expected, file: file, line: line)
        XCTAssertLessThan(elapsed, 1, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: readiness.path), file: file, line: line)
        Self.assertProcessGone(pid, file: file, line: line)
        try FileManager.default.removeItem(at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), file: file, line: line)
    }

    private static func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoAnalyzerLifecycle-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func assertProcessGone(
        _ pid: Int32, file: StaticString, line: UInt
    ) {
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "Owned PID \(pid) is still alive.", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }

    private static let lifecycleProgram = #"""
import json, os, pathlib, signal, time
mode = os.environ["OPENFINDER_LIFECYCLE_MODE"]
readiness = pathlib.Path(os.environ["OPENFINDER_LIFECYCLE_READINESS"])
pathlib.Path(os.environ["OPENFINDER_LIFECYCLE_PID"]).write_text(str(os.getpid()), encoding="utf-8")
signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode != "timeout":
    payload = "{malformed" if mode == "malformed" else json.dumps({"pid": os.getpid() + 100000, "port": 12345})
    temporary = readiness.with_suffix(".tmp")
    temporary.write_text(payload, encoding="utf-8")
    os.replace(temporary, readiness)
time.sleep(30)
"""#
}
