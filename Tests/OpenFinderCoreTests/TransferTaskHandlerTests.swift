import Foundation
import XCTest
@testable import OpenFinderCore

final class TransferTaskHandlerTests: XCTestCase {
    func testTransferEnvelopeRoundTripsDeterministicallyWithoutSecrets() async throws {
        // Given
        let fixture = try TransferHandlerFixture()
        defer { fixture.cleanup() }
        let provider = LocalFileProvider()
        let entries = try await fixture.sourceURLs.asyncMap {
            TransferEntrySnapshot(try await provider.stat(.local(path: $0.path)))
        }
        let envelope = TransferTaskEnvelope(
            entries: entries,
            source: .local(path: fixture.source.path),
            destination: .local(path: fixture.destination.path),
            overwrite: .rejectExisting,
            sourceRevision: "source-r1",
            destinationRevision: "destination-r1"
        )
        let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        // When
        let first = try envelope.makeDescriptor(
            taskID: taskID,
            handlerID: .transferCopy,
            resourceKey: "transfer:destination",
            idempotencyKey: "copy:fixture",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: 7
        )
        let second = try envelope.makeDescriptor(
            taskID: taskID,
            handlerID: .transferCopy,
            resourceKey: "transfer:destination",
            idempotencyKey: "copy:fixture",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: 7
        )
        let decoded = try TransferTaskEnvelope.decode(from: first)

        // Then
        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.entries.map(\.name), ["01-alpha.txt", "02-bravo.txt"])
        XCTAssertEqual(first.resourceKey, "transfer:destination")
        XCTAssertEqual(first.idempotencyKey, "copy:fixture")
        XCTAssertEqual(first.lineage.attempt, 1)
        XCTAssertEqual(first.queueOrdinal, 7)
        let payload = try XCTUnwrap(first.redactedPayload[TransferTaskEnvelope.payloadKey])
        XCTAssertFalse(payload.localizedCaseInsensitiveContains("secret"))
        XCTAssertFalse(payload.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(payload.localizedCaseInsensitiveContains("credential"))
        print(
            "TRANSFER_ENVELOPE payloadBytes=\(payload.utf8.count) " +
            "order=\(decoded.entries.map(\.name)) resourceKey=\(first.resourceKey ?? "missing")"
        )
    }

    func testQueuedPersistedCopyRestoresAndExecutesInDescriptorOrder() async throws {
        // Given
        let fixture = try TransferHandlerFixture()
        defer { fixture.cleanup() }
        let descriptor = try await fixture.makeDescriptor(overwrite: .rejectExisting)
        let descriptorData = try JSONEncoder().encode(descriptor)
        let sources = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { accountID, revision in
                throw RemoteProviderRegistry.UnsupportedProviderError(
                    accountID: accountID,
                    revision: revision
                )
            }
        )
        let handlers = TaskHandlerRegistry()
        try await handlers.register(
            TransferCopyTaskHandler(
                fileSources: sources,
                coordinator: TransferCoordinator()
            ).taskHandler
        )
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: handlers)

        // When
        let taskID = try await queue.recoverPersistedTask(
            .init(kind: .localCopy, title: "Recovered copy"),
            descriptorData: descriptorData
        )
        let record = try await queue.waitForTerminalStatus(taskID, timeout: 2)
        let finalRecord = await queue.record(for: taskID)

        // Then
        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(record.descriptor?.resourceKey, descriptor.resourceKey)
        XCTAssertEqual(
            try fixture.destinationURLs.map { try Data(contentsOf: $0) },
            [Data("alpha".utf8), Data("bravo".utf8)]
        )
        XCTAssertEqual(finalRecord?.progressDetail?.completed, 2)
        print(
            "COPY_RECOVERY status=\(record.status.rawValue) " +
            "order=\(fixture.destinationURLs.map(\.lastPathComponent)) " +
            "bytes=\(try fixture.destinationURLs.map { try Data(contentsOf: $0).base64EncodedString() })"
        )
    }

    func testInterruptedRetryRevalidatesMutatedDestinationWithoutOverwrite() async throws {
        // Given
        let fixture = try TransferHandlerFixture()
        defer { fixture.cleanup() }
        try Data("selected destination".utf8).write(to: fixture.destinationURLs[0])
        let provider = LocalFileProvider()
        let selectedDestination = TransferEntrySnapshot(
            try await provider.stat(.local(path: fixture.destinationURLs[0].path))
        )
        let descriptor = try await fixture.makeDescriptor(
            overwrite: .replaceExisting,
            destinationSnapshots: [selectedDestination, nil],
            attempt: 2
        )
        try Data("changed after interruption".utf8).write(to: fixture.destinationURLs[0])
        let sources = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { accountID, revision in
                throw RemoteProviderRegistry.UnsupportedProviderError(
                    accountID: accountID,
                    revision: revision
                )
            }
        )
        let handlers = TaskHandlerRegistry()
        try await handlers.register(
            TransferCopyTaskHandler(
                fileSources: sources,
                coordinator: TransferCoordinator()
            ).taskHandler
        )
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: handlers)

        // When
        let taskID = try await queue.enqueue(.init(
            kind: .localCopy,
            title: "Interrupted copy retry",
            descriptor: descriptor
        ))
        let record = try await queue.waitForTerminalStatus(taskID, timeout: 2)

        // Then
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue(record.errorMessage?.contains("destinationConflict") == true)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationURLs[0]),
            Data("changed after interruption".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURLs[1].path))
        print(
            "COPY_RETRY status=\(record.status.rawValue) intervention=destinationConflict " +
            "overwrite=false untouchedSecond=true"
        )
    }

    func testMalformedTransferPayloadFailsWithoutFilesystemEffects() async throws {
        // Given
        let fixture = try TransferHandlerFixture()
        defer { fixture.cleanup() }
        let taskID = UUID()
        let malformed = TaskDescriptorEnvelope(
            taskID: taskID,
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1,
            resourceKey: "transfer:\(fixture.destination.path)",
            idempotencyKey: "copy:malformed",
            lineage: .init(rootTaskID: taskID),
            queueOrdinal: 1,
            redactedPayload: [TransferTaskEnvelope.payloadKey: #"{"entries":"invalid"}"#]
        )
        let sources = FileSourceRegistry(
            remoteProviderRegistry: RemoteProviderRegistry { accountID, revision in
                throw RemoteProviderRegistry.UnsupportedProviderError(
                    accountID: accountID,
                    revision: revision
                )
            }
        )
        let handlers = TaskHandlerRegistry()
        try await handlers.register(TransferCopyTaskHandler(fileSources: sources).taskHandler)
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: handlers)

        // When
        let queuedID = try await queue.enqueue(.init(
            kind: .localCopy,
            title: "Malformed transfer",
            descriptor: malformed
        ))
        let record = try await queue.waitForTerminalStatus(queuedID, timeout: 2)

        // Then
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.errorMessage, TransferTaskEnvelopeError.malformedPayload.localizedDescription)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty
        )
    }
}

private struct TransferHandlerFixture {
    let root: URL
    let source: URL
    let destination: URL
    let sourceURLs: [URL]
    let destinationURLs: [URL]

    init() throws {
        let createdRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderTransferHandler-\(UUID().uuidString)", isDirectory: true)
        let createdSource = createdRoot.appendingPathComponent("source", isDirectory: true)
        let createdDestination = createdRoot.appendingPathComponent(
            "destination",
            isDirectory: true
        )
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
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: sourceURLs[0])
        try Data("bravo".utf8).write(to: sourceURLs[1])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeDescriptor(
        overwrite: TransferOverwritePolicy,
        destinationSnapshots: [TransferEntrySnapshot?]? = nil,
        attempt: Int = 1
    ) async throws -> TaskDescriptorEnvelope {
        let provider = LocalFileProvider()
        let entries = try await sourceURLs.asyncMap {
            TransferEntrySnapshot(try await provider.stat(.local(path: $0.path)))
        }
        let taskID = UUID()
        return try TransferTaskEnvelope(
            entries: entries,
            source: .local(path: source.path),
            destination: .local(path: destination.path),
            overwrite: overwrite,
            destinationSnapshots: destinationSnapshots
        ).makeDescriptor(
            taskID: taskID,
            handlerID: .transferCopy,
            resourceKey: "transfer:\(destination.path)",
            idempotencyKey: "copy:\(taskID.uuidString)",
            lineage: .init(rootTaskID: taskID, attempt: attempt),
            queueOrdinal: UInt64(attempt)
        )
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
