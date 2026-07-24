import Foundation
import XCTest
@testable import OpenFinderCore

final class TransferCoordinatorTests: XCTestCase {
    func testSupportedTransferMatrix() {
        let accountA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let accountB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let local = FileSourceID.local
        let remoteA = FileSourceID.remote(accountID: accountA, connectorID: .kodbox)
        let remoteB = FileSourceID.remote(accountID: accountB, connectorID: .kodbox)
        let webDAVA = FileSourceID.remote(accountID: accountA, connectorID: .webDAV)

        XCTAssertEqual(TransferCoordinator.support(from: local, to: local, overwrite: .rejectExisting), .supported)
        XCTAssertEqual(TransferCoordinator.support(from: local, to: remoteA, overwrite: .rejectExisting), .supported)
        XCTAssertEqual(TransferCoordinator.support(from: remoteA, to: local, overwrite: .replaceExisting), .supported)
        XCTAssertEqual(TransferCoordinator.support(from: remoteA, to: remoteA, overwrite: .rejectExisting), .supported)
        XCTAssertEqual(
            TransferCoordinator.support(from: local, to: remoteA, overwrite: .replaceExisting),
            .unsupported(.remoteOverwrite)
        )
        XCTAssertEqual(
            TransferCoordinator.support(from: remoteA, to: remoteA, overwrite: .replaceExisting),
            .unsupported(.remoteOverwrite)
        )
        XCTAssertEqual(
            TransferCoordinator.support(from: remoteA, to: remoteB, overwrite: .rejectExisting),
            .unsupported(.crossSource)
        )
        XCTAssertEqual(
            TransferCoordinator.support(from: remoteA, to: webDAVA, overwrite: .rejectExisting),
            .unsupported(.crossSource)
        )
    }

    func testPartialMoveRetryRequiresIntervention() async throws {
        let fixture = try LocalTransferFixture()
        defer { fixture.cleanup() }
        let provider = LocalFileProvider()
        let snapshots = try await fixture.sourceURLs.asyncMap {
            TransferEntrySnapshot(try await provider.stat(.local(path: $0.path)))
        }
        let request = TransferRequest(
            taskID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            operation: .move,
            entries: snapshots,
            source: .local(path: fixture.source.path),
            destination: .local(path: fixture.destination.path),
            overwrite: .rejectExisting
        )
        let coordinator = TransferCoordinator()

        do {
            try await coordinator.execute(
                request,
                operations: .local(),
                faultPoint: .afterItem(1)
            )
            XCTFail("Expected deterministic interruption after the first item")
        } catch let error as TransferExecutionError {
            XCTAssertEqual(error, .injectedFailure(completedItems: 1))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURLs[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destinationURLs[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURLs[1].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURLs[1].path))

        do {
            try await coordinator.execute(request, operations: .local())
            XCTFail("Retry must stop at preflight instead of silently resuming a partial move")
        } catch let intervention as TransferIntervention {
            XCTAssertEqual(intervention.taskID, request.taskID)
            XCTAssertEqual(intervention.itemID, snapshots[0].id)
            XCTAssertEqual(intervention.reason, .alreadyMoved)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURLs[1].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURLs[1].path))
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURLs[0]), Data("alpha".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURLs[1]), Data("bravo".utf8))
    }

    func testRetryAlwaysRepreflightsStaleSnapshotAndConflictBeforeEffects() async throws {
        let fixture = try LocalTransferFixture()
        defer { fixture.cleanup() }
        let provider = LocalFileProvider()
        let snapshot = TransferEntrySnapshot(
            try await provider.stat(.local(path: fixture.sourceURLs[0].path))
        )
        try Data("changed after selection".utf8).write(to: fixture.sourceURLs[0])
        let request = TransferRequest(
            taskID: UUID(),
            operation: .copy,
            entries: [snapshot],
            source: .local(path: fixture.source.path),
            destination: .local(path: fixture.destination.path),
            overwrite: .rejectExisting
        )

        do {
            try await TransferCoordinator().execute(request, operations: .local())
            XCTFail("A stale immutable snapshot must require intervention")
        } catch let intervention as TransferIntervention {
            XCTAssertEqual(intervention.reason, .sourceChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURLs[0].path))
    }

    func testBatchPreflightFindsLaterConflictBeforeCopyingEarlierItem() async throws {
        let fixture = try LocalTransferFixture()
        defer { fixture.cleanup() }
        try Data("existing".utf8).write(to: fixture.destinationURLs[1])
        let provider = LocalFileProvider()
        let entries = try await fixture.sourceURLs.asyncMap {
            TransferEntrySnapshot(try await provider.stat(.local(path: $0.path)))
        }
        let request = TransferRequest(
            taskID: UUID(),
            operation: .copy,
            entries: entries,
            source: .local(path: fixture.source.path),
            destination: .local(path: fixture.destination.path),
            overwrite: .rejectExisting
        )

        do {
            try await TransferCoordinator().execute(request, operations: .local())
            XCTFail("The later conflict must stop the entire batch during preflight")
        } catch let intervention as TransferIntervention {
            XCTAssertEqual(intervention.itemID, entries[1].id)
            XCTAssertEqual(intervention.reason, .destinationConflict)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURLs[0].path))
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURLs[1]), Data("existing".utf8))
    }

    func testCancelledAttemptCanOnlyRunAfterExplicitRetry() async throws {
        let fixture = try LocalTransferFixture()
        defer { fixture.cleanup() }
        let provider = LocalFileProvider()
        let entry = TransferEntrySnapshot(
            try await provider.stat(.local(path: fixture.sourceURLs[0].path))
        )
        let request = TransferRequest(
            taskID: UUID(),
            operation: .copy,
            entries: [entry],
            source: .local(path: fixture.source.path),
            destination: .local(path: fixture.destination.path),
            overwrite: .rejectExisting
        )
        let coordinator = TransferCoordinator()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await coordinator.execute(request, operations: .local())
        }

        do {
            try await cancelled.value
            XCTFail("A cancelled attempt must not perform an effect")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURLs[0].path))

        try await coordinator.execute(request, operations: .local())
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURLs[0]), Data("alpha".utf8))
    }

    func testManualFilesystemCopyMoveOrderFaultRetryAndCleanup() async throws {
        let fixture = try LocalTransferFixture()
        let provider = LocalFileProvider()
        let entries = try await fixture.sourceURLs.asyncMap {
            TransferEntrySnapshot(try await provider.stat(.local(path: $0.path)))
        }
        let progress = ProgressCapture()
        let copyRequest = TransferRequest(
            taskID: UUID(),
            operation: .copy,
            entries: entries,
            source: .local(path: fixture.source.path),
            destination: .local(path: fixture.destination.path),
            overwrite: .rejectExisting
        )
        try await TransferCoordinator().execute(
            copyRequest,
            operations: .local(),
            progress: { await progress.append($0) }
        )
        let progressValues = await progress.values()
        XCTAssertEqual(progressValues.compactMap(\.completed), [0, 1, 1, 2])
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURLs[0]), Data("alpha".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURLs[1]), Data("bravo".utf8))
        do {
            try await TransferCoordinator().execute(copyRequest, operations: .local())
            XCTFail("A copied destination must require intervention on replay")
        } catch let intervention as TransferIntervention {
            XCTAssertEqual(intervention.reason, .alreadyCopied)
        }

        let copiedTree = try FileManager.default.contentsOfDirectory(
            atPath: fixture.destination.path
        ).sorted()
        print(
            "MANUAL_QA copyTree=\(copiedTree) " +
            "bytes=\(try fixture.destinationURLs.map { try Data(contentsOf: $0).base64EncodedString() }) " +
            "progress=\(progressValues.compactMap(\.completed))"
        )

        fixture.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        print("MANUAL_QA cleanupRootExists=false")
    }

    func testMisleadingSuccessAndLongCancellationRequireExplicitRepreflight() async throws {
        let movedFixture = try LocalTransferFixture()
        defer { movedFixture.cleanup() }
        let provider = LocalFileProvider()
        let movedEntry = TransferEntrySnapshot(
            try await provider.stat(.local(path: movedFixture.sourceURLs[0].path))
        )
        let movedRequest = TransferRequest(
            taskID: UUID(),
            operation: .move,
            entries: [movedEntry],
            source: .local(path: movedFixture.source.path),
            destination: .local(path: movedFixture.destination.path),
            overwrite: .rejectExisting
        )
        let local = TransferFileOperations.local()
        let misleading = TransferFileOperations(
            snapshotSource: { try await local.sourceSnapshot(for: $0) },
            snapshotDestination: {
                try await local.destinationSnapshot(for: $0, at: $1)
            },
            execute: { operation, entry, destination, overwrite in
                try await local.execute(
                    operation,
                    entry: entry,
                    destination: destination,
                    overwrite: overwrite
                )
                throw TransferProbeError.reportedFailureAfterEffect
            }
        )
        let coordinator = TransferCoordinator()

        do {
            try await coordinator.execute(movedRequest, operations: misleading)
            XCTFail("The probe must report failure after performing the move")
        } catch TransferProbeError.reportedFailureAfterEffect {}
        do {
            try await coordinator.execute(movedRequest, operations: local)
            XCTFail("Repreflight must expose the already-moved effect")
        } catch let intervention as TransferIntervention {
            XCTAssertEqual(intervention.reason, .alreadyMoved)
        }
        XCTAssertEqual(
            try Data(contentsOf: movedFixture.destinationURLs[0]),
            Data("alpha".utf8)
        )

        let cancelledFixture = try LocalTransferFixture()
        defer { cancelledFixture.cleanup() }
        let cancelledEntry = TransferEntrySnapshot(
            try await provider.stat(.local(path: cancelledFixture.sourceURLs[0].path))
        )
        let cancelledRequest = TransferRequest(
            taskID: UUID(),
            operation: .copy,
            entries: [cancelledEntry],
            source: .local(path: cancelledFixture.source.path),
            destination: .local(path: cancelledFixture.destination.path),
            overwrite: .rejectExisting
        )
        let delayed = TransferFileOperations(
            snapshotSource: { try await local.sourceSnapshot(for: $0) },
            snapshotDestination: {
                try await local.destinationSnapshot(for: $0, at: $1)
            },
            execute: { operation, entry, destination, overwrite in
                try await Task.sleep(for: .seconds(5))
                try await local.execute(
                    operation,
                    entry: entry,
                    destination: destination,
                    overwrite: overwrite
                )
            }
        )
        let cancelledCoordinator = TransferCoordinator()
        let longOperation = Task {
            try await cancelledCoordinator.execute(
                cancelledRequest,
                operations: delayed
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        longOperation.cancel()
        do {
            try await longOperation.value
            XCTFail("Cancellation must stop the delayed operation")
        } catch is CancellationError {}
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cancelledFixture.destinationURLs[0].path)
        )
        try await cancelledCoordinator.execute(cancelledRequest, operations: local)
        XCTAssertEqual(
            try Data(contentsOf: cancelledFixture.destinationURLs[0]),
            Data("alpha".utf8)
        )
    }

    func testMalformedSourceAndDestinationNeverPerformEffects() async throws {
        let fixture = try LocalTransferFixture()
        defer { fixture.cleanup() }
        let provider = LocalFileProvider()
        let entry = TransferEntrySnapshot(
            try await provider.stat(.local(path: fixture.sourceURLs[0].path))
        )
        let wrongSourceRequest = TransferRequest(
            taskID: UUID(),
            operation: .copy,
            entries: [entry],
            source: .local(path: fixture.root.path),
            destination: .local(path: fixture.destination.path),
            overwrite: .rejectExisting
        )
        do {
            try await TransferCoordinator().execute(
                wrongSourceRequest,
                operations: .local()
            )
            XCTFail("An entry outside the declared source must be rejected")
        } catch let intervention as TransferIntervention {
            XCTAssertEqual(intervention.reason, .sourceChanged)
        }

        let invalidDestination = fixture.root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: invalidDestination)
        let invalidDestinationRequest = TransferRequest(
            taskID: UUID(),
            operation: .copy,
            entries: [entry],
            source: .local(path: fixture.source.path),
            destination: .local(path: invalidDestination.path),
            overwrite: .rejectExisting
        )
        do {
            try await TransferCoordinator().execute(
                invalidDestinationRequest,
                operations: .local()
            )
            XCTFail("A non-directory destination must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a directory"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURLs[0].path))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURLs[0]), Data("alpha".utf8))
    }
}

private struct LocalTransferFixture {
    let root: URL
    let source: URL
    let destination: URL
    let sourceURLs: [URL]
    let destinationURLs: [URL]

    init() throws {
        let createdRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderTransferCoordinator-\(UUID().uuidString)", isDirectory: true)
        let createdSource = createdRoot.appendingPathComponent("source", isDirectory: true)
        let createdDestination = createdRoot.appendingPathComponent("destination", isDirectory: true)
        let createdSourceURLs = [
            createdSource.appendingPathComponent("01-alpha.txt"),
            createdSource.appendingPathComponent("02-bravo.txt")
        ]
        root = createdRoot
        source = createdSource
        destination = createdDestination
        sourceURLs = createdSourceURLs
        destinationURLs = createdSourceURLs.map {
            createdDestination.appendingPathComponent($0.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: createdSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: createdDestination, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: sourceURLs[0])
        try Data("bravo".utf8).write(to: sourceURLs[1])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}

private actor ProgressCapture {
    private var snapshots: [TaskProgressSnapshot] = []

    func append(_ snapshot: TaskProgressSnapshot) {
        snapshots.append(snapshot)
    }

    func values() -> [TaskProgressSnapshot] {
        snapshots
    }
}

private enum TransferProbeError: Error {
    case reportedFailureAfterEffect
}
