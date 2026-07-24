import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class TaskRecoveryIntegrationTests: XCTestCase {
    func testStartupReadinessAndQueuedRestore() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let sourceFile = fixture.source.appendingPathComponent("queued.txt")
        try Data("queued recovery".utf8).write(to: sourceFile)
        let descriptor = try await fixture.transferDescriptor(
            sourceFile: sourceFile,
            handlerID: .transferCopy,
            queueOrdinal: 41
        )
        try await fixture.store.enqueue(
            descriptor: descriptor,
            record: TaskRecord(
                id: descriptor.taskID,
                kind: .localCopy,
                title: "Queued recovery",
                descriptor: descriptor
            )
        )

        let app = fixture.makeApp()
        try await waitUntil {
            app.durableHandlerReadiness == .ready
                && FileManager.default.fileExists(
                    atPath: fixture.destination.appendingPathComponent("queued.txt").path
                )
        }

        let record = try XCTUnwrap(app.taskRecords.first { $0.id == descriptor.taskID })
        XCTAssertEqual(record.status, .succeeded)
        let copiedData = try Data(
            contentsOf: fixture.destination.appendingPathComponent("queued.txt")
        )
        XCTAssertEqual(copiedData, Data("queued recovery".utf8))
        print(
            "TASK18_READINESS_OBSERVABLE readiness=ready"
                + " queueOrdinal=\(descriptor.queueOrdinal)"
                + " status=\(record.status.rawValue)"
                + " copiedBytes=\(copiedData.count)"
        )
    }

    func testRunningMoveBecomesInterruptedWithoutExecution() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let sourceFile = fixture.source.appendingPathComponent("running.txt")
        try Data("must remain".utf8).write(to: sourceFile)
        let descriptor = try await fixture.transferDescriptor(
            sourceFile: sourceFile,
            handlerID: .transferMove,
            queueOrdinal: 42
        )
        try await fixture.store.enqueue(
            descriptor: descriptor,
            record: TaskRecord(
                id: descriptor.taskID,
                kind: .localMove,
                title: "Running move",
                status: .running,
                createdAt: Date(timeIntervalSince1970: 1_735_689_500),
                startedAt: Date(timeIntervalSince1970: 1_735_689_600),
                descriptor: descriptor
            )
        )

        let app = fixture.makeApp()
        try await waitUntil {
            app.durableHandlerReadiness == .ready
                && app.taskRecords.contains {
                    $0.id == descriptor.taskID && $0.status == .interrupted
                }
        }

        let record = try XCTUnwrap(app.taskRecords.first { $0.id == descriptor.taskID })
        XCTAssertEqual(record.reasonCode, .recoveryInterrupted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("running.txt").path
        ))
        print(
            "TASK18_INTERRUPT_OBSERVABLE readiness=ready"
                + " status=\(record.status.rawValue)"
                + " reason=\(record.reasonCode?.rawValue ?? "nil")"
                + " sourceExists=true destinationExists=false"
        )
    }

    func testUnknownRecoveredDependencyBecomesUnavailable() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let taskID = UUID()
        let descriptor = TaskDescriptorEnvelope(
            taskID: taskID,
            handlerID: "fixture.removed-handler.v1",
            payloadVersion: 1,
            resourceKey: "fixture:removed-dependency",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: 43
        )
        try await fixture.store.enqueue(
            descriptor: descriptor,
            record: TaskRecord(
                id: taskID,
                kind: .localCopy,
                title: "Removed dependency",
                descriptor: descriptor
            )
        )

        let app = fixture.makeApp()
        try await waitUntil {
            app.durableHandlerReadiness == .ready
                && app.taskRecords.contains {
                    $0.id == taskID && $0.status == .unavailable
                }
        }

        let record = try XCTUnwrap(app.taskRecords.first { $0.id == taskID })
        XCTAssertEqual(record.reasonCode, .unknownHandler)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< 300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for startup recovery")
    }
}

private final class RecoveryFixture {
    let root: URL
    let source: URL
    let destination: URL
    let databaseURL: URL
    let store: GRDBTaskStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskRecovery-\(UUID())", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        databaseURL = root.appendingPathComponent("tasks.sqlite")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        store = GRDBTaskStore(database: try AppDatabase(url: databaseURL))
    }

    func transferDescriptor(
        sourceFile: URL,
        handlerID: DurableTaskHandlerID,
        queueOrdinal: UInt64
    ) async throws -> TaskDescriptorEnvelope {
        let item = try await LocalFileProvider().stat(.local(path: sourceFile.path))
        let taskID = UUID()
        return try TransferTaskEnvelope(
            entries: [.init(item)],
            source: .local(path: source.path),
            destination: .local(path: destination.path),
            overwrite: .rejectExisting
        ).makeDescriptor(
            taskID: taskID,
            handlerID: handlerID,
            resourceKey: "fixture:destination",
            idempotencyKey: "fixture:\(taskID)",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: queueOrdinal
        )
    }

    @MainActor
    func makeApp() -> AppModel {
        AppModel(
            remoteDirectory: RemoteAccountDirectory(
                storageURL: root.appendingPathComponent("accounts.json")
            ),
            configurationStore: JSONConfigStore(
                url: root.appendingPathComponent("config.json")
            ),
            keychainStore: InMemoryKeychainStore(),
            taskDatabaseURL: databaseURL
        )
    }

    func cleanup() {
        if let receiptPath = ProcessInfo.processInfo.environment[
            "OPENFINDER_TASK18_FIXTURE_RECEIPT"
        ] {
            try? root.path.write(
                toFile: receiptPath,
                atomically: true,
                encoding: .utf8
            )
            return
        }
        try? FileManager.default.removeItem(at: root)
    }
}
