import Darwin
import Foundation

struct HTTPCharacterizationObservation: Decodable, Equatable {
    let method: String
    let path: String
    let authorizationAccepted: Bool
    let submittedTaskID: UUID?
    let submittedSecretsEmpty: Bool?
}

enum HTTPCharacterizationServerError: Error, Equatable, Sendable {
    case invalidReadiness
    case processExited(Int32)
    case readinessTimedOut
}

enum HTTPCharacterizationResponseMode: String, Sendable {
    case standard
    case malformedSSE
    case mediaAnalysis
}

final class PortZeroHTTPCharacterizationServer: @unchecked Sendable {
    let endpoint: String
    let token: String
    let processIdentifier: Int32

    private let process: Process
    private let observationsURL: URL
    private let terminationGrace: TimeInterval

    init(
        root: URL,
        program: String? = nil,
        readinessTimeout: TimeInterval = 2,
        terminationGrace: TimeInterval = 2,
        responseMode: HTTPCharacterizationResponseMode = .standard
    ) throws {
        token = "baseline-\(UUID().uuidString.lowercased())"
        observationsURL = root.appendingPathComponent("observations.json")
        self.terminationGrace = terminationGrace
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", program ?? Self.program]
        var environment = ProcessInfo.processInfo.environment
        environment["OPENFINDER_CHARACTERIZATION_TOKEN"] = token
        environment["OPENFINDER_CHARACTERIZATION_OBSERVATIONS"] = observationsURL.path
        environment["OPENFINDER_CHARACTERIZATION_RESPONSE_MODE"] = responseMode.rawValue
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        self.process = process
        try process.run()
        processIdentifier = process.processIdentifier
        do {
            let readiness = try Self.readLine(
                output.fileHandleForReading, process: process, timeout: readinessTimeout
            )
            guard readiness.hasPrefix("READY "),
                  let port = Int(readiness.dropFirst("READY ".count)),
                  (1 ... 65_535).contains(port), process.isRunning
            else { throw HTTPCharacterizationServerError.invalidReadiness }
            endpoint = "http://127.0.0.1:\(port)"
        } catch {
            Self.terminate(process, pid: processIdentifier, grace: terminationGrace)
            try? output.fileHandleForReading.close()
            throw error
        }
    }

    func observations() throws -> [HTTPCharacterizationObservation] {
        try JSONDecoder().decode([HTTPCharacterizationObservation].self, from: Data(contentsOf: observationsURL))
    }

    func stop() {
        Self.terminate(process, pid: processIdentifier, grace: terminationGrace)
    }

    private static func terminate(_ process: Process, pid: Int32, grace: TimeInterval) {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { Darwin.kill(pid, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    private static func readLine(
        _ handle: FileHandle, process: Process, timeout: TimeInterval
    ) throws -> String {
        var data = Data()
        let descriptorNumber = handle.fileDescriptor
        let originalFlags = Darwin.fcntl(descriptorNumber, F_GETFL)
        guard originalFlags >= 0,
              Darwin.fcntl(descriptorNumber, F_SETFL, originalFlags | O_NONBLOCK) == 0
        else { throw HTTPCharacterizationServerError.invalidReadiness }
        defer { _ = Darwin.fcntl(descriptorNumber, F_SETFL, originalFlags) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while data.count < 128 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw HTTPCharacterizationServerError.readinessTimedOut }
            if !process.isRunning {
                throw HTTPCharacterizationServerError.processExited(process.terminationStatus)
            }
            var descriptor = pollfd(
                fd: descriptorNumber, events: Int16(POLLIN | POLLHUP), revents: 0
            )
            let milliseconds = Int32(max(1, min(20, ceil(remaining * 1_000))))
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result == 0 { continue }
            if result < 0 {
                if errno == EINTR { continue }
                throw HTTPCharacterizationServerError.invalidReadiness
            }
            if descriptor.revents & Int16(POLLIN) != 0 {
                var buffer = [UInt8](repeating: 0, count: 128 - data.count)
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptorNumber, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    let chunk = buffer.prefix(count)
                    if let newline = chunk.firstIndex(of: 0x0a) {
                        data.append(contentsOf: chunk[..<newline])
                        return String(decoding: data, as: UTF8.self)
                    }
                    data.append(contentsOf: chunk)
                    continue
                }
                if count == 0 { break }
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                throw HTTPCharacterizationServerError.invalidReadiness
            }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { break }
        }
        if !process.isRunning {
            throw HTTPCharacterizationServerError.processExited(process.terminationStatus)
        }
        throw HTTPCharacterizationServerError.invalidReadiness
    }

    private static let program = #"""
import hashlib, http.server, json, os, pathlib, uuid

TOKEN = os.environ["OPENFINDER_CHARACTERIZATION_TOKEN"]
OBSERVATIONS = os.environ["OPENFINDER_CHARACTERIZATION_OBSERVATIONS"]
RESPONSE_MODE = os.environ.get("OPENFINDER_CHARACTERIZATION_RESPONSE_MODE", "standard")
records = []
media_artifacts = {}

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass
    def record(self, body=None):
        accepted = self.headers.get("Authorization") == "Bearer " + TOKEN
        record = {"method": self.command, "path": self.path, "authorizationAccepted": accepted}
        if body is not None:
            record["submittedTaskID"] = body.get("taskID")
            record["submittedSecretsEmpty"] = body.get("secrets") == {}
        records.append(record)
        with open(OBSERVATIONS, "w", encoding="utf-8") as handle:
            json.dump(records, handle)
        return accepted
    def send_json(self, value, status=200):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("OpenFinder-Plugin-Protocol", "1")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if not self.record():
            return self.send_json({"schemaVersion":1,"code":"unauthorized","message":"denied","retryable":False}, 401)
        if self.path.endswith("/health"):
            return self.send_json({"schemaVersion":1,"protocolVersion":1,"status":"ready","pluginID":"dev.openfinder.plugins.video-analyzer","pluginVersion":"0.1.0","runtime":{"name":"Python","version":"3"},"checks":[]})
        if self.path.endswith("/capabilities"):
            return self.send_json({"schemaVersion":1,"protocolVersion":1,"pluginID":"dev.openfinder.plugins.video-analyzer","pluginVersion":"0.1.0","actions":[{"id":"analyze-video"}],"features":{"sse":True,"polling":True,"cancellation":True,"fileArtifacts":True},"limits":{"maxRequestBytes":1048576,"terminalRetentionSeconds":1800,"maxEventsPerJob":10000,"maxQueuedJobs":100}})
        task_id = self.path.split("/")[-2] if self.path.endswith("/result") or self.path.endswith("/events") else ""
        artifacts = media_artifacts.get(task_id, [])
        result = {"schemaVersion":1,"eventID":2,"taskID":task_id,"type":"result","status":"success","artifacts":artifacts}
        if self.path.endswith("/events"):
            if RESPONSE_MODE == "malformedSSE":
                body = b"id: 1\nevent: progress\ndata: {not-json}\n\n"
                self.send_response(200); self.send_header("Content-Type", "text/event-stream")
                self.send_header("OpenFinder-Plugin-Protocol", "1"); self.send_header("Content-Length", str(len(body)))
                self.end_headers(); self.wfile.write(body); self.wfile.flush(); return
            progress = {"schemaVersion":1,"eventID":1,"taskID":task_id,"type":"progress","fraction":0.5,"message":"1/2","phase":"characterization","completed":1,"total":2,"unit":"steps"}
            frames = "id: 1\nevent: progress\ndata: " + json.dumps(progress, separators=(",", ":")) + "\n\nid: 2\nevent: result\ndata: " + json.dumps(result, separators=(",", ":")) + "\n\n"
            body = frames.encode()
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            self.send_header("OpenFinder-Plugin-Protocol", "1"); self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body); self.wfile.flush(); return
        if self.path.endswith("/result"):
            return self.send_json(result)
        self.send_json({"schemaVersion":1,"code":"not_found","message":"missing","retryable":False}, 404)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if not self.record(body):
            return self.send_json({"schemaVersion":1,"code":"unauthorized","message":"denied","retryable":False}, 401)
        task_id = body["taskID"].lower()
        if RESPONSE_MODE == "mediaAnalysis":
            document = {"schemaID":"mediaAnalysis.v1","schemaVersion":1,
                        "documentID":"11111111-1111-1111-1111-111111111111",
                        "taskID":task_id,"items":[],"suggestedTags":[],"actions":[],
                        "managedTagLedger":{"mediaEntries":[]},"createdAt":"2025-01-01T00:00:00Z"}
            data = json.dumps(document,separators=(",", ":")).encode()
            output = pathlib.Path(body["outputDirectory"])
            output.mkdir(parents=True, exist_ok=True)
            (output / "media-analysis.json").write_bytes(data)
            media_artifacts[task_id] = [{"type":"mediaAnalysis.v1",
                "artifactID":str(uuid.uuid5(uuid.NAMESPACE_URL, task_id + "/media-analysis.json")),
                "relativePath":"media-analysis.json","mediaType":"application/json",
                "byteCount":len(data),"sha256":hashlib.sha256(data).hexdigest()}]
        self.send_json({"schemaVersion":1,"taskID":task_id,"state":"queued","createdAt":"2026-07-18T00:00:00Z","updatedAt":"2026-07-18T00:00:00Z","startedAt":None,"finishedAt":None,"lastEventID":0,"resultAvailable":False}, 202)

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print("READY " + str(server.server_address[1]), flush=True)
server.serve_forever()
"""#
}
