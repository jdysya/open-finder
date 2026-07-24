import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppApplicationServiceIntegrationTests: XCTestCase {
    func testStartupTasksAccountsAndTransfers() async throws {
        let fixture = try ApplicationServiceFixture()
        defer { fixture.cleanup() }
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let app = fixture.makeApp(taskQueue: queue)
        try await waitUntil { app.durableHandlerReadiness == .ready }

        app.addRemoteAccount(
            connectorID: .webDAV,
            name: "Service account",
            endpoint: "https://example.invalid/dav",
            username: "tester",
            password: "",
            allowInsecureHTTP: false
        )
        XCTAssertEqual(app.remoteAccounts.map(\.name), ["Service account"])

        let sourceFile = fixture.source.appendingPathComponent("service.txt")
        try Data("application services".utf8).write(to: sourceFile)
        let item = try await LocalFileProvider().stat(.local(path: sourceFile.path))
        let taskID = try await app.fileBrowserService.submitTransfer(
            [item],
            source: .local(path: fixture.source.path),
            destination: .local(path: fixture.destination.path),
            move: false,
            overwriteExisting: false,
            title: "Service transfer"
        )
        let record = try await app.taskApplicationService.waitForTerminalStatus(
            taskID,
            timeout: 2
        ).0
        await app.refreshTasks()

        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(app.taskRecords.first { $0.id == taskID }?.status, .succeeded)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("service.txt")),
            Data("application services".utf8)
        )
        print(
            "TASK27_SERVICES readiness=ready accounts=\(app.remoteAccounts.count)"
                + " task=\(record.status.rawValue) transferBytes=20"
        )
    }

    func testPollingCannotStartBeforeDurableReadiness() async throws {
        let service = TaskApplicationService(queue: TaskQueueService())
        let gate = ReadinessGate()
        let readiness = Task<Result<Void, any Error>, Never> {
            await gate.wait()
            return .success(())
        }
        service.attachReadinessTask(readiness)
        service.startPolling { _ in }

        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(service.pollingState, .waitingForReadiness)

        await gate.open()
        try await waitUntil { service.pollingState == .polling }
        print("TASK27_POLLING before=waitingForReadiness after=polling")
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< 300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for application service state")
    }
}

private final class ApplicationServiceFixture {
    let root: URL
    let source: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationServices-\(UUID())", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    @MainActor
    func makeApp(taskQueue: TaskQueueService) -> AppModel {
        AppModel(
            remoteDirectory: RemoteAccountDirectory(
                storageURL: root.appendingPathComponent("accounts.json")
            ),
            configurationStore: JSONConfigStore(
                url: root.appendingPathComponent("configuration.json")
            ),
            keychainStore: InMemoryKeychainStore(),
            taskQueue: taskQueue,
            videoAnalysisStore: VideoAnalysisResultStore(
                directory: root.appendingPathComponent("analysis", isDirectory: true)
            ),
            startAutomatically: false
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ReadinessGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}
