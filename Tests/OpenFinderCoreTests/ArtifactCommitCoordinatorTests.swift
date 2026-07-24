import CryptoKit
import Foundation
import XCTest
@testable import OpenFinderCore

final class ArtifactCommitCoordinatorTests: XCTestCase {
    func testCommitPersistsBeforeWorkspaceCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backend = InMemoryArtifactMetadataBackend()
        let store = try ArtifactStore(root: fixture.storeRoot, metadata: backend)
        let coordinator = ArtifactCommitCoordinator(store: store, metadata: backend)
        let source = try fixture.write("nested/report.json", data: Data("durable".utf8))
        let frame = try fixture.write("nested/media/frame-0001.jpg", data: Data("frame".utf8))
        let observation = TestFlag()

        let records = try await coordinator.commit(
            taskID: fixture.taskID,
            schemaID: "report.v1",
            artifacts: [source, frame],
            from: ConfinedArtifactReader(root: fixture.workspace),
            markEffectsCommitted: {},
            cleanupWorkspace: {
                await observation.set(await backend.taskEffectsCommitted(fixture.taskID))
                try FileManager.default.removeItem(at: fixture.workspace)
            }
        )

        let observedCommittedBeforeCleanup = await observation.value
        XCTAssertTrue(observedCommittedBeforeCleanup)
        XCTAssertEqual(records.map(\.state), [.committed, .committed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.path))
        let persisted = try await store.read(records[0])
        XCTAssertEqual(persisted, Data("durable".utf8))
        XCTAssertEqual(SHA256.hexDigest(persisted), source.sha256)
        let persistedFrame = try await store.read(records[1])
        XCTAssertEqual(persistedFrame, Data("frame".utf8))
        XCTAssertEqual(SHA256.hexDigest(persistedFrame), frame.sha256)
        let tree = FileManager.default.enumerator(atPath: fixture.storeRoot.path)?
            .compactMap { $0 as? String }.sorted() ?? []
        print(
            "TASK9_MANUAL_QA states=\(records.map { $0.state.rawValue }) " +
                "digests=\([source.sha256, frame.sha256]) tree=\(tree)"
        )
    }

    func testCleanupFailureDoesNotPersistUnderlyingSecret() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backend = InMemoryArtifactMetadataBackend()
        let store = try ArtifactStore(root: fixture.storeRoot, metadata: backend)
        let coordinator = ArtifactCommitCoordinator(store: store, metadata: backend)
        let source = try fixture.write("result.bin", data: Data("payload".utf8))
        let secret = "bearer-token=fixture-secret"

        let records = try await coordinator.commit(
            taskID: fixture.taskID,
            schemaID: "secret-safe.v1",
            artifacts: [source],
            from: ConfinedArtifactReader(root: fixture.workspace),
            markEffectsCommitted: {},
            cleanupWorkspace: {
                throw SecretBearingCleanupError(secret: secret)
            }
        )

        XCTAssertEqual(records.first?.state, .committed)
        let persisted = await backend.cleanupFailure(taskID: fixture.taskID)
        XCTAssertEqual(persisted, ArtifactCommitCoordinator.cleanupFailureMessage)
        XCTAssertFalse(persisted?.contains(secret) == true)

        let report = await coordinator.reconcileAtStartup()
        let issue = try XCTUnwrap(report.issues.first {
            $0.taskID == fixture.taskID && $0.kind == .cleanupFailure
        })
        XCTAssertEqual(issue.detail, ArtifactCommitCoordinator.cleanupFailureMessage)
        XCTAssertFalse(issue.detail.contains(secret))
    }

    func testReconcilesEveryFilesystemDatabaseSplit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backend = InMemoryArtifactMetadataBackend()
        let store = try ArtifactStore(root: fixture.storeRoot, metadata: backend)
        let coordinator = ArtifactCommitCoordinator(store: store, metadata: backend)
        let source = try fixture.write("nested/result.bin", data: Data("payload".utf8))
        let reader = try ConfinedArtifactReader(root: fixture.workspace)

        let orphanID = UUID()
        let orphan = await store.stagingURL(taskID: fixture.taskID, artifactID: orphanID)
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan)

        let missing = ArtifactRecord(
            id: UUID(), schemaID: "missing.v1",
            relativePath: "published/\(fixture.taskID.uuidString)/missing.bin",
            mediaType: "application/octet-stream", byteCount: 7, sha256: source.sha256,
            state: .filePublished, stagedAt: .now
        )
        try await backend.upsert(missing, taskID: fixture.taskID)

        var published = try await store.stage(
            taskID: fixture.taskID, schemaID: "publish.v1", artifact: source, from: reader
        )
        published = try await store.publish(published, taskID: fixture.taskID)
        let linkedBefore = await backend.isLinked(published.id, to: fixture.taskID)
        XCTAssertFalse(linkedBefore)

        let first = await coordinator.reconcileAtStartup()
        let second = await coordinator.reconcileAtStartup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let linkedAfter = await backend.isLinked(published.id, to: fixture.taskID)
        XCTAssertTrue(linkedAfter)
        XCTAssertTrue(first.issues.contains { $0.artifactID == missing.id && $0.kind == .missingFile })
        XCTAssertTrue(second.issues.contains { $0.artifactID == missing.id && $0.kind == .missingFile })
        let reconciledState = await backend.record(id: published.id)?.state
        XCTAssertEqual(reconciledState, .rowLinked)

        let unknownPublished = fixture.storeRoot
            .appendingPathComponent("published/unknown/orphan.bin")
        try FileManager.default.createDirectory(
            at: unknownPublished.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("unknown".utf8).write(to: unknownPublished)
        let orphanReport = await coordinator.reconcileAtStartup()
        XCTAssertTrue(orphanReport.issues.contains {
            $0.kind == .orphanedPublishedFile && $0.path == unknownPublished.path
        })

        try Data("corrupt".utf8).write(to: fixture.storeRoot.appendingPathComponent(published.relativePath))
        let corruptReport = await coordinator.reconcileAtStartup()
        XCTAssertTrue(corruptReport.issues.contains {
            $0.artifactID == published.id && $0.kind == .corruptFile
        })

        await backend.recordCleanupFailure(taskID: fixture.taskID, message: "workspace busy")
        let cleanupReport = await coordinator.reconcileAtStartup()
        XCTAssertTrue(cleanupReport.issues.contains {
            $0.taskID == fixture.taskID && $0.kind == .cleanupFailure && $0.detail == "workspace busy"
        })
    }

    func testVerifiedCopyRejectsMalformedSymlinkSizeAndHash() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let valid = try fixture.write("asset.bin", data: Data("valid".utf8))
        let reader = try ConfinedArtifactReader(root: fixture.workspace)
        let destination = fixture.root.appendingPathComponent("copy.bin")

        XCTAssertThrowsError(try reader.copy(
            artifact: .init(
                relativePath: valid.relativePath, mediaType: valid.mediaType,
                byteCount: valid.byteCount + 1, sha256: valid.sha256
            ),
            to: destination
        )) { XCTAssertEqual($0 as? ConfinedArtifactError, .sizeMismatch) }

        XCTAssertThrowsError(try reader.copy(
            artifact: .init(
                relativePath: valid.relativePath, mediaType: valid.mediaType,
                byteCount: valid.byteCount, sha256: String(repeating: "0", count: 64)
            ),
            to: destination
        )) { XCTAssertEqual($0 as? ConfinedArtifactError, .hashMismatch) }

        let outside = fixture.root.appendingPathComponent("outside.bin")
        try Data("outside".utf8).write(to: outside)
        let link = fixture.workspace.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try reader.copy(
            artifact: .init(relativePath: "link.bin", mediaType: "application/octet-stream", byteCount: 7, sha256: valid.sha256),
            to: destination
        ))
    }

    func testCancellationBeforeCommitRollsBackAndAfterCommitPreservesArtifact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backend = InMemoryArtifactMetadataBackend()
        let store = try ArtifactStore(root: fixture.storeRoot, metadata: backend)
        let coordinator = ArtifactCommitCoordinator(store: store, metadata: backend)
        let source = try fixture.write("asset.bin", data: Data("value".utf8))
        let reader = try ConfinedArtifactReader(root: fixture.workspace)

        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.commit(
                taskID: fixture.taskID, schemaID: "cancel.v1", artifacts: [source], from: reader,
                markEffectsCommitted: {}, cleanupWorkspace: {}
            )
        }
        await XCTAssertThrowsCancellationError { try await preCancelled.value }
        let recordsAfterCancellation = await backend.records()
        XCTAssertTrue(recordsAfterCancellation.isEmpty)

        let committed = try await coordinator.commit(
            taskID: fixture.taskID, schemaID: "cancel.v1", artifacts: [source], from: reader,
            markEffectsCommitted: { withUnsafeCurrentTask { $0?.cancel() } },
            cleanupWorkspace: {}
        )
        XCTAssertEqual(committed.first?.state, .committed)
        let committedData = try await store.read(committed[0])
        XCTAssertEqual(committedData, Data("value".utf8))
    }

    func testStoreRejectsPersistentRootReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backend = InMemoryArtifactMetadataBackend()
        let store = try ArtifactStore(root: fixture.storeRoot, metadata: backend)
        let source = try fixture.write("asset.bin", data: Data("value".utf8))
        let displaced = fixture.root.appendingPathComponent("displaced-store")
        try FileManager.default.moveItem(at: fixture.storeRoot, to: displaced)
        try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: true)

        do {
            _ = try await store.stage(
                taskID: fixture.taskID,
                schemaID: "root.v1",
                artifact: source,
                from: ConfinedArtifactReader(root: fixture.workspace)
            )
            XCTFail("Expected replaced store root to be rejected")
        } catch {
            XCTAssertEqual(error as? ArtifactStoreError, .invalidRoot)
        }
    }

    func testMetadataFailureAfterTaskCommitPreservesPublishedArtifactForReconciliation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backend = FailingCommitMetadataBackend()
        let store = try ArtifactStore(root: fixture.storeRoot, metadata: backend)
        let coordinator = ArtifactCommitCoordinator(store: store, metadata: backend)
        let source = try fixture.write("asset.bin", data: Data("preserve".utf8))
        let observation = TestFlag()

        do {
            _ = try await coordinator.commit(
                taskID: fixture.taskID,
                schemaID: "failure.v1",
                artifacts: [source],
                from: ConfinedArtifactReader(root: fixture.workspace),
                markEffectsCommitted: { await observation.set(true) },
                cleanupWorkspace: { XCTFail("Cleanup must not run after metadata commit failure") }
            )
            XCTFail("Expected injected metadata failure")
        } catch {
            XCTAssertTrue(error is InjectedMetadataError)
        }

        let didCommitEffects = await observation.value
        XCTAssertTrue(didCommitEffects)
        let entries = await backend.entries()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.record.state, .rowLinked)
        let data = try await store.read(entry.record)
        XCTAssertEqual(data, Data("preserve".utf8))
    }
}

private struct Fixture {
    let root: URL
    let workspace: URL
    let storeRoot: URL
    let taskID = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactCommitCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, data: Data) throws -> PluginFileArtifact {
        let url = workspace.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return .init(
            relativePath: relativePath, mediaType: "application/octet-stream",
            byteCount: data.count, sha256: SHA256.hexDigest(data)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension SHA256 {
    static func hexDigest(_ data: Data) -> String {
        hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor TestFlag {
    private(set) var value = false

    func set(_ value: Bool) {
        self.value = value
    }
}

private struct InjectedMetadataError: Error {}

private struct SecretBearingCleanupError: Error, CustomStringConvertible {
    let secret: String

    var description: String { "Cleanup failed: \(secret)" }
}

private actor FailingCommitMetadataBackend: ArtifactMetadataBackend {
    private let base = InMemoryArtifactMetadataBackend()

    func upsert(_ record: ArtifactRecord, taskID: UUID) async throws {
        try await base.upsert(record, taskID: taskID)
    }

    func record(id: UUID) async -> ArtifactRecord? {
        await base.record(id: id)
    }

    func entries() async -> [ArtifactMetadataEntry] {
        await base.entries()
    }

    func remove(id: UUID) async {
        await base.remove(id: id)
    }

    func link(_ artifactID: UUID, to taskID: UUID) async throws {
        try await base.link(artifactID, to: taskID)
    }

    func isLinked(_ artifactID: UUID, to taskID: UUID) async -> Bool {
        await base.isLinked(artifactID, to: taskID)
    }

    func markTaskEffectsCommitted(_ taskID: UUID) async throws {
        throw InjectedMetadataError()
    }

    func taskEffectsCommitted(_ taskID: UUID) async -> Bool {
        await base.taskEffectsCommitted(taskID)
    }

    func recordCleanupFailure(taskID: UUID, message: String) async {
        await base.recordCleanupFailure(taskID: taskID, message: message)
    }

    func cleanupFailure(taskID: UUID) async -> String? {
        await base.cleanupFailure(taskID: taskID)
    }

    func clearCleanupFailure(taskID: UUID) async {
        await base.clearCleanupFailure(taskID: taskID)
    }
}

private func XCTAssertThrowsCancellationError<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected CancellationError", file: file, line: line)
    } catch is CancellationError {
        return
    } catch {
        XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
    }
}
