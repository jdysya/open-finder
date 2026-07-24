import Foundation
import XCTest
@testable import OpenFinderCore

final class PluginArtifactTests: XCTestCase {
    func testLegacyInlineArtifactRoundTrips() throws {
        let artifact = PluginArtifact(type: "text", content: "secret text")

        let data = try JSONEncoder.openFinder.encode(artifact)
        let decoded = try JSONDecoder.openFinder.decode(PluginArtifact.self, from: data)

        XCTAssertEqual(decoded, artifact)
        XCTAssertEqual(decoded.content, "secret text")
        XCTAssertNil(decoded.file)
    }

    func testFileArtifactRoundTripsWithoutInlineContent() throws {
        let file = PluginFileArtifact(
            relativePath: "results/result.json",
            mediaType: "application/json",
            byteCount: 12,
            sha256: String(repeating: "a", count: 64)
        )
        let artifact = PluginArtifact(type: MediaAnalysisDocument.schemaIdentifier, file: file)

        let decoded = try JSONDecoder.openFinder.decode(
            PluginArtifact.self,
            from: JSONEncoder.openFinder.encode(artifact)
        )

        XCTAssertEqual(decoded, artifact)
        XCTAssertNil(decoded.content)
        XCTAssertEqual(decoded.file, file)
    }

    func testDecoderRejectsBothNeitherAndPartialPayloads() {
        let hash = String(repeating: "a", count: 64)
        let invalid = [
            #"{"type":"x"}"#,
            #"{"type":"x","content":"inline","relativePath":"x","mediaType":"text/plain","byteCount":1,"sha256":"\#(hash)"}"#,
            #"{"type":"x","relativePath":"x","mediaType":"text/plain"}"#,
            #"{"type":"x","relativePath":"x","mediaType":"text/plain","byteCount":1}"#
        ]

        for json in invalid {
            XCTAssertThrowsError(
                try JSONDecoder.openFinder.decode(PluginArtifact.self, from: Data(json.utf8)),
                "Expected rejection for \(json)"
            )
        }
    }

    func testRedactorChangesOnlyInlineTextAndPreservesFileMetadata() {
        let token = "secret-token"
        let file = PluginFileArtifact(
            relativePath: "secret-token/result.json",
            mediaType: "application/secret-token",
            byteCount: 42,
            sha256: String(repeating: "b", count: 64)
        )
        let event = PluginOutputEvent.result(
            status: "success",
            message: token,
            clipboard: nil,
            artifacts: [
                .init(type: "inline-secret-token", content: token),
                .init(type: "file-secret-token", file: file)
            ]
        )

        guard case .result(_, let message, _, let artifacts) = HTTPPluginRedactor.event(event, token: token) else {
            return XCTFail("Expected result")
        }

        XCTAssertEqual(message, "REDACTED")
        XCTAssertEqual(artifacts[0].type, "inline-secret-token")
        XCTAssertEqual(artifacts[0].content, "REDACTED")
        XCTAssertEqual(artifacts[1], .init(type: "file-secret-token", file: file))
    }
}
