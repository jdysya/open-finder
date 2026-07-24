import Foundation
import XCTest
@testable import OpenFinderCore

final class TransferMovePartialRecoveryTests: XCTestCase {
    func testPartialRemoteToLocalMoveRetryNeverDeletesReusedSourceOrMutatesDestination()
        async throws
    {
        // Given
        let fixture = try MoveHandlerFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.sourceFile)
        let accountID = UUID(uuidString: "56565656-5656-5656-5656-565656565656")!
        let remote = FakeMoveRemoteProvider(deleteFault: .afterEffect)
        let original = Data("remote-original".utf8)
        let replacement = Data("replacement-at-reused-path".utf8)
        await remote.store(
            original,
            at: "/source/item.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        let entry = await remoteEntry(
            accountID: accountID,
            path: "/source/item.txt",
            provider: remote
        )
        let queue = try await makeRemoteQueue(provider: remote)
        let originalTaskID = UUID(uuidString: "67676767-6767-6767-6767-676767676767")!
        let envelope = TransferTaskEnvelope(
            entries: [entry],
            source: remoteLocation(accountID: accountID, path: "/source"),
            destination: .local(path: fixture.destination.path),
            overwrite: .rejectExisting
        )
        let descriptor = try envelope.makeDescriptor(
            taskID: originalTaskID,
            handlerID: .transferMove,
            resourceKey: "move:remote-local",
            idempotencyKey: "move:remote-local",
            lineage: .init(rootTaskID: originalTaskID),
            queueOrdinal: 1
        )

        // When
        let firstID = try await queue.enqueue(.init(
            kind: .webDAVDownload,
            title: "Partial remote/local move",
            descriptor: descriptor
        ))
        let first = try await queue.waitForTerminalStatus(firstID, timeout: 2)
        await remote.store(
            replacement,
            at: "/source/item.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_735_689_700)
        )
        let retryID = try await queue.retry(firstID)
        let retry = try await queue.waitForTerminalStatus(retryID, timeout: 2)

        // Then
        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(retry.status, .failed)
        XCTAssertTrue(retry.errorMessage?.contains("sourceChanged") == true)
        let observables = await remote.observables()
        XCTAssertEqual(observables.downloadCount, 1)
        XCTAssertEqual(observables.deleteCount, 1)
        XCTAssertEqual(observables.files["/source/item.txt"], replacement)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationFile), original)
        print(
            "MOVE_RETRY_OBSERVABLE first=\(first.status.rawValue) retry=\(retry.status.rawValue) " +
            "downloads=\(observables.downloadCount) deletes=\(observables.deleteCount) " +
            "reusedSourcePreserved=true destinationPreserved=true"
        )
    }

    func testPartialLocalToRemoteMoveRetryNeverMutatesReusedSourceOrRemoteDestination()
        async throws
    {
        // Given
        let fixture = try MoveHandlerFixture()
        defer { fixture.cleanup() }
        let accountID = UUID(uuidString: "78787878-7878-7878-7878-787878787878")!
        let remote = FakeMoveRemoteProvider()
        let original = Data("original".utf8)
        let replacement = Data("replacement-at-reused-local-path".utf8)
        let destructiveLocal = LocalFileProvider { url in
            try FileManager.default.removeItem(at: url)
            throw FakeMoveRemoteFault.afterEffect
        }
        let entry = TransferEntrySnapshot(
            try await destructiveLocal.stat(.local(path: fixture.sourceFile.path))
        )
        let queue = try await makeRemoteQueue(
            provider: remote,
            localProvider: destructiveLocal
        )
        let originalTaskID = UUID(uuidString: "89898989-8989-8989-8989-898989898989")!
        let envelope = TransferTaskEnvelope(
            entries: [entry],
            source: .local(path: fixture.source.path),
            destination: remoteLocation(accountID: accountID, path: "/destination"),
            overwrite: .rejectExisting
        )
        let descriptor = try envelope.makeDescriptor(
            taskID: originalTaskID,
            handlerID: .transferMove,
            resourceKey: "move:local-remote",
            idempotencyKey: "move:local-remote",
            lineage: .init(rootTaskID: originalTaskID),
            queueOrdinal: 1
        )

        // When
        let firstID = try await queue.enqueue(.init(
            kind: .webDAVUpload,
            title: "Partial local/remote move",
            descriptor: descriptor
        ))
        let first = try await queue.waitForTerminalStatus(firstID, timeout: 2)
        try replacement.write(to: fixture.sourceFile)
        let retryID = try await queue.retry(firstID)
        let retry = try await queue.waitForTerminalStatus(retryID, timeout: 2)

        // Then
        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(retry.status, .failed)
        XCTAssertTrue(retry.errorMessage?.contains("sourceChanged") == true)
        let observables = await remote.observables()
        XCTAssertEqual(observables.uploadCount, 1)
        XCTAssertEqual(observables.files["/destination/item.txt"], original)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceFile), replacement)
    }
}
