import Foundation
import XCTest
@testable import OpenFinderCore

final class HTTPPluginTransportStreamingTests: XCTestCase {
    func testFlushedSSEFrameArrivesBeforeLongLivedConnectionCloses() async throws {
        let server = try LoopbackStreamingFixture()
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/events")!)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let response = try await URLSessionHTTPPluginTransport().stream(for: request)

        let firstChunk = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var iterator = response.chunks.makeAsyncIterator()
                guard let chunk = try await iterator.next() else { throw StreamingFixtureError.noChunk }
                return chunk
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(300))
                throw StreamingFixtureError.timeout
            }
            guard let first = try await group.next() else { throw StreamingFixtureError.noChunk }
            group.cancelAll()
            return first
        }

        XCTAssertEqual(String(decoding: firstChunk, as: UTF8.self), ": ping\n")
        XCTAssertTrue(server.isRunning, "The first flushed SSE line must arrive before EOF.")
    }
}

private enum StreamingFixtureError: Error { case timeout, noChunk, invalidReadiness }

private final class LoopbackStreamingFixture: @unchecked Sendable {
    let port: Int
    private let process: Process

    init() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.program]
        process.standardOutput = output
        process.standardError = output
        self.process = process
        try process.run()
        let line = try Self.readLine(output.fileHandleForReading)
        guard line.hasPrefix("READY "), let parsed = Int(line.dropFirst("READY ".count)) else {
            process.terminate()
            process.waitUntilExit()
            throw StreamingFixtureError.invalidReadiness
        }
        port = parsed
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private static func readLine(_ handle: FileHandle) throws -> String {
        var data = Data()
        while data.count < 128 {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else { break }
            if byte[0] == 0x0a { return String(decoding: data, as: UTF8.self) }
            data.append(byte)
        }
        throw StreamingFixtureError.invalidReadiness
    }

    private static let program = """
    import socket, time
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', 0))
    server.listen(1)
    print(f'READY {server.getsockname()[1]}', flush=True)
    connection, _ = server.accept()
    request = b''
    while b'\\r\\n\\r\\n' not in request:
        request += connection.recv(4096)
    connection.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: text/event-stream; charset=utf-8\\r\\nOpenFinder-Plugin-Protocol: 1\\r\\nCache-Control: no-store\\r\\nConnection: close\\r\\n\\r\\n')
    connection.sendall(b': ping\\n\\n')
    time.sleep(1.0)
    connection.sendall(b': after\\n\\n')
    connection.close()
    server.close()
    """
}
