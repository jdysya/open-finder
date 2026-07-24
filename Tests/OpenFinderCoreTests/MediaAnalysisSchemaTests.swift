import Foundation
import XCTest
@testable import OpenFinderCore

final class MediaAnalysisSchemaTests: XCTestCase {
    func testCurrentMediaDocumentRoundTripsAsV1() throws {
        let frameArtifact = committedArtifact(id: frameArtifactID, path: "frames/frame-7.jpg")
        let artifacts = [frameArtifact.id: frameArtifact]
        let document = self.document(
            asset: .init(artifactID: frameArtifactID, relativePath: "frames/frame-7.jpg")
        )
        try document.validate(artifacts: artifacts)

        let data = try JSONEncoder.openFinder.encode(document)
        let decoded = try JSONDecoder.openFinder.decode(MediaAnalysisDocument.self, from: data)
        try decoded.validate(artifacts: artifacts)

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.schemaID, "mediaAnalysis.v1")
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.taskID, document.taskID)
        XCTAssertEqual(decoded.items.single?.media.sourcePath, "/media/demo.mp4")
        XCTAssertEqual(decoded.items.single?.media.displayName, "demo.mp4")
        XCTAssertEqual(decoded.items.single?.summaryMetrics.map(\.key), ["totalFrames"])
        XCTAssertEqual(decoded.items.single?.moments.single?.index, 0)
        XCTAssertEqual(decoded.items.single?.moments.single?.timestamp, 0)
        XCTAssertEqual(decoded.actions, MediaAnalysisAction.standard)
        print("SCHEMA_OBSERVABLE schemaID=\(decoded.schemaID) version=\(decoded.schemaVersion) mediaID=\(decoded.items[0].media.stableID) metrics=\(decoded.items[0].summaryMetrics.count) moments=\(decoded.items[0].moments.count)")
    }

    func testRejectsAbsoluteOrUncommittedAssetReference() throws {
        let absolute = document(
            asset: .init(artifactID: frameArtifactID, relativePath: "/tmp/frame.jpg")
        )
        XCTAssertThrowsError(try absolute.validate(artifacts: [
            frameArtifactID: committedArtifact(id: frameArtifactID, path: "frames/frame.jpg")
        ])) { error in
            XCTAssertEqual(error as? MediaAnalysisValidationError, .absoluteAssetPath("/tmp/frame.jpg"))
            print("VALIDATION_OBSERVABLE rejected=absoluteAssetPath")
        }

        let staging = document(
            asset: .init(artifactID: frameArtifactID, relativePath: "frames/frame.jpg")
        )
        let stagingRecord = ArtifactRecord(
            id: frameArtifactID,
            schemaID: MediaAnalysisDocument.schemaIdentifier,
            relativePath: "frames/frame.jpg",
            mediaType: "image/jpeg",
            byteCount: 10,
            sha256: String(repeating: "a", count: 64),
            state: .staging,
            stagedAt: referenceDate
        )
        XCTAssertThrowsError(try staging.validate(artifacts: [frameArtifactID: stagingRecord])) { error in
            XCTAssertEqual(error as? MediaAnalysisValidationError, .artifactNotCommitted(frameArtifactID))
            print("VALIDATION_OBSERVABLE rejected=artifactNotCommitted")
        }

        XCTAssertThrowsError(try staging.validate(artifacts: [:])) { error in
            XCTAssertEqual(error as? MediaAnalysisValidationError, .unknownArtifact(frameArtifactID))
            print("VALIDATION_OBSERVABLE rejected=unknownArtifact")
        }

        let traversing = document(
            asset: .init(artifactID: frameArtifactID, relativePath: "frames/../frame.jpg")
        )
        XCTAssertThrowsError(try traversing.validate(artifacts: [
            frameArtifactID: committedArtifact(id: frameArtifactID, path: "frames/../frame.jpg")
        ])) { error in
            XCTAssertEqual(error as? MediaAnalysisValidationError, .unconfinedAssetPath("frames/../frame.jpg"))
        }
    }

    func testRejectsFutureVersionAndMissingRequiredFields() throws {
        let future = Data(#"{"schemaID":"mediaAnalysis.v1","schemaVersion":2,"documentID":"11111111-1111-1111-1111-111111111111","taskID":"22222222-2222-2222-2222-222222222222","items":[],"suggestedTags":[],"actions":[],"managedTagLedger":{"mediaEntries":[]},"createdAt":"2025-01-01T00:00:00Z"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder.openFinder.decode(MediaAnalysisDocument.self, from: future)) { error in
            XCTAssertEqual(error as? MediaAnalysisValidationError, .unsupportedSchemaVersion(2))
        }

        let missingItems = Data(#"{"schemaID":"mediaAnalysis.v1","schemaVersion":1,"documentID":"11111111-1111-1111-1111-111111111111","taskID":"22222222-2222-2222-2222-222222222222","suggestedTags":[],"actions":[],"managedTagLedger":{"mediaEntries":[]},"createdAt":"2025-01-01T00:00:00Z"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder.openFinder.decode(MediaAnalysisDocument.self, from: missingItems))

        let legacy = Data(#"{"schemaID":"videoAnalysisResult","schemaVersion":1,"documentID":"11111111-1111-1111-1111-111111111111","taskID":"22222222-2222-2222-2222-222222222222","items":[],"suggestedTags":[],"actions":[],"managedTagLedger":{"mediaEntries":[]},"createdAt":"2025-01-01T00:00:00Z"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder.openFinder.decode(MediaAnalysisDocument.self, from: legacy)) { error in
            XCTAssertEqual(error as? MediaAnalysisValidationError, .unsupportedSchemaID("videoAnalysisResult"))
        }
    }

    func testUnknownFieldsCannotChangeTypedRendererInput() throws {
        let baseline = try JSONEncoder.openFinder.encode(document(
            asset: .init(artifactID: frameArtifactID, relativePath: "frames/frame.jpg")
        ))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        object["rendererTitle"] = "ATTACKER CONTROLLED"
        let decoded = try JSONDecoder.openFinder.decode(
            MediaAnalysisDocument.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded, try JSONDecoder.openFinder.decode(MediaAnalysisDocument.self, from: baseline))
    }

    func testLifecycleCancellationRetentionAndIdempotentReconciliation() throws {
        var record = ArtifactRecord(
            id: frameArtifactID,
            schemaID: MediaAnalysisDocument.schemaIdentifier,
            relativePath: "frames/frame.jpg",
            mediaType: "image/jpeg",
            byteCount: 10,
            sha256: String(repeating: "a", count: 64),
            state: .staging,
            stagedAt: referenceDate
        )
        XCTAssertEqual(record.reconciliationState, .validate)
        record = try record.transition(to: .validated)
        record = try record.transition(to: .filePublished)
        XCTAssertEqual(record.reconciliationState, .linkRow)
        XCTAssertEqual(record.reconciliationState, .linkRow)
        record = try record.transition(to: .rowLinked)
        XCTAssertEqual(record.reconciliationState, .commit)

        let beforeCommitCancellation = try record.cancelling(at: referenceDate.addingTimeInterval(10))
        XCTAssertEqual(beforeCommitCancellation.state, .cleaned)
        XCTAssertEqual(beforeCommitCancellation.finishedAt, referenceDate.addingTimeInterval(10))
        XCTAssertEqual(try beforeCommitCancellation.cancelling(), beforeCommitCancellation)

        let finishedAt = referenceDate.addingTimeInterval(20)
        record = try record.transition(to: .committed, at: finishedAt)
        XCTAssertEqual(record.finishedAt, finishedAt)
        XCTAssertEqual(record.retentionDeadline, finishedAt.addingTimeInterval(30 * 24 * 60 * 60))
        XCTAssertEqual(try record.cancelling(at: finishedAt.addingTimeInterval(1)), record)
        XCTAssertEqual(record.reconciliationState, .stable)
        XCTAssertThrowsError(try record.cleaningExpired(at: finishedAt.addingTimeInterval(29 * 24 * 60 * 60)))
        XCTAssertEqual(
            try record.cleaningExpired(at: finishedAt.addingTimeInterval(30 * 24 * 60 * 60)).state,
            .cleaned
        )
    }

    func testManagedTagLedgerReplacesOnlyPreviouslyManagedTags() {
        let ledger = ManagedTagLedger(mediaEntries: [
            .init(stableMediaID: "sha256:stable-demo", tagNames: ["old-auto", "keep-auto"])
        ])
        let reconciliation = ledger.reconcile(
            stableMediaID: "sha256:stable-demo",
            currentTagNames: ["manual", "old-auto", "keep-auto"],
            suggestedTagNames: ["keep-auto", "new-auto"]
        )

        XCTAssertEqual(reconciliation.remove, ["old-auto"])
        XCTAssertEqual(reconciliation.add, ["new-auto"])
        XCTAssertEqual(reconciliation.nextManaged, ["keep-auto", "new-auto"])
    }

    private let frameArtifactID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let referenceDate = Date(timeIntervalSince1970: 1_735_689_600)

    private func document(asset: ConfinedAssetReference) -> MediaAnalysisDocument {
        MediaAnalysisDocument(
            documentID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            taskID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            items: [.init(
                media: .init(stableID: "sha256:stable-demo", sourcePath: "/media/demo.mp4", displayName: "demo.mp4"),
                summaryMetrics: [.init(key: "totalFrames", value: 1, unit: .count)],
                facets: [],
                moments: [.init(index: 0, timestamp: 0, summary: "", facets: [], assets: [asset], suggestedTags: [])],
                suggestedTags: [],
                report: nil
            )],
            suggestedTags: [],
            actions: MediaAnalysisAction.standard,
            managedTagLedger: .init(mediaEntries: []),
            createdAt: referenceDate
        )
    }

    private func committedArtifact(id: UUID, path: String) -> ArtifactRecord {
        ArtifactRecord(
            id: id,
            schemaID: MediaAnalysisDocument.schemaIdentifier,
            relativePath: path,
            mediaType: path.hasSuffix(".jpg") ? "image/jpeg" : "application/json",
            byteCount: 10,
            sha256: String(repeating: "a", count: 64),
            state: .committed,
            stagedAt: referenceDate,
            finishedAt: referenceDate
        )
    }
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
