import Foundation
import XCTest
@testable import OpenFinderCore

final class FileSourceCapabilityContractTests: XCTestCase {
    private let webDAVAccount = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherWebDAVAccount = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let kodboxAccount = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testProviderAndRelationalMatrix() {
        let sources = sourceCases
        for source in sources {
            let capabilities = FileSourceCapabilities(sourceID: source.id)
            for capability in FileCapability.allCases {
                XCTAssertEqual(
                    capabilities[capability],
                    source.expectedUnsupported[capability]
                        .map(FileCapabilitySupport.unsupported) ?? .supported,
                    "\(source.name) \(capability)"
                )
            }
        }

        var relationalCells = 0
        for source in sources {
            for destination in sources {
                for overwriteExisting in [false, true] {
                    let relation = FileRelationalCapabilities(
                        source: source.id,
                        destination: destination.id,
                        overwriteExisting: overwriteExisting
                    )
                    for capability in [FileCapability.copy, .move] {
                        let expected: FileCapabilitySupport
                        if source.id.isRemote,
                           destination.id.isRemote,
                           source.id != destination.id {
                            expected = .unsupported(.crossSource)
                        } else if overwriteExisting && destination.id.isRemote {
                            expected = .unsupported(.remoteOverwrite)
                        } else {
                            expected = .supported
                        }
                        XCTAssertEqual(
                            relation[capability],
                            expected,
                            "\(source.name) -> \(destination.name) \(capability) overwrite=\(overwriteExisting)"
                        )
                        relationalCells += 1
                    }
                }
            }
        }

        XCTAssertEqual(relationalCells, 100)
        print("MATRIX providerCells=\(sources.count * FileCapability.allCases.count) relationalCells=\(relationalCells) exactTypedOutcomes=true")
    }

    func testUnsupportedRcloneAndCrossAccountRemainTyped() {
        let rcloneID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let legacy = Location.rclone(remoteID: rcloneID, path: "archive:photos")
        XCTAssertEqual(legacy.fileLocation, .unsupported(.legacyRclone(remoteID: rcloneID)))

        let first = FileSourceID.remote(accountID: webDAVAccount, connectorID: .webDAV)
        let second = FileSourceID.remote(accountID: otherWebDAVAccount, connectorID: .webDAV)
        let relation = FileRelationalCapabilities(source: first, destination: second)
        XCTAssertEqual(relation.copy, .unsupported(.crossSource))
        XCTAssertEqual(relation.move, .unsupported(.crossSource))

        let unknown = FileSourceID.remote(accountID: webDAVAccount, connectorID: "unknown")
        XCTAssertEqual(
            FileSourceCapabilities(sourceID: unknown)[.list],
            .unsupported(.unknownSource(connectorID: "unknown"))
        )
    }

    func testLegacyWebDAVNormalizesWithoutChangingLocationCodable() throws {
        let legacy = Location.webDAV(accountID: webDAVAccount, path: "/photos")
        XCTAssertEqual(
            legacy.fileLocation,
            .resolved(
                FileLocation(
                    sourceID: .remote(accountID: webDAVAccount, connectorID: .webDAV),
                    path: .init(identifier: "/photos", displayPath: "/photos")
                )
            )
        )

        let encoded = try JSONEncoder().encode(legacy)
        XCTAssertEqual(try JSONDecoder().decode(Location.self, from: encoded), legacy)
    }

    func testEffectiveCapabilitiesUseListingAndItemMetadataWithoutRemoteStat() {
        let source = FileSourceID.remote(accountID: kodboxAccount, connectorID: .kodbox)
        let sourceCapabilities = FileSourceCapabilities(sourceID: source)
        XCTAssertEqual(sourceCapabilities[.create], .supported)
        XCTAssertEqual(sourceCapabilities[.tags], .supported)

        let listing = FileListingCapabilities(
            sourceID: source,
            metadata: RemoteDirectoryCapabilities(
                isReadable: true,
                isWritable: false,
                supportsTags: false
            )
        )
        XCTAssertEqual(listing[.list], .supported)
        XCTAssertEqual(listing[.create], .unsupported(.listingMetadataDenied))
        XCTAssertEqual(listing[.tags], .unsupported(.listingMetadataDenied))

        let item = FileItemCapabilities(
            sourceID: source,
            metadata: RemoteItem(
                id: "listed-item",
                name: "listed.txt",
                path: .init(identifier: "{source:1}/listed.txt", displayPath: "/listed.txt"),
                kind: .file,
                size: nil,
                modificationDate: nil,
                etag: nil,
                mimeType: nil,
                isReadable: false,
                isWritable: true,
                supportsTagEditing: false
            )
        )
        XCTAssertEqual(item[.read], .unsupported(.itemMetadataDenied))
        XCTAssertEqual(item[.delete], .supported)
        XCTAssertEqual(item[.tags], .unsupported(.itemMetadataDenied))
    }

    func testMalformedLegacyLocationStillFailsDecode() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Location.self,
                from: Data("{\"type\":\"webDAV\",\"accountID\":\"bad\",\"path\":null}".utf8)
            )
        )
    }

    func testAdapterPreflightAndPresentationIndependentlyPreserveTypedReason() {
        let rcloneID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let expected = FileCapabilityUnsupportedReason.legacyRclone(remoteID: rcloneID)
        guard case .unsupported(let adapterReason) = Location
            .rclone(remoteID: rcloneID, path: "archive:")
            .fileLocation
        else {
            return XCTFail("Expected typed adapter rejection")
        }

        let decision = FileCapabilityDecision.rejected(adapterReason)
        let candidate = FileLocation(
            sourceID: .local,
            path: .init(identifier: "/tmp/archive", displayPath: "/tmp/archive")
        )

        XCTAssertEqual(
            FileLocationCapabilityAdapter.apply(decision, to: candidate),
            .unsupported(expected)
        )
        XCTAssertEqual(
            FileOperationPreflight.evaluate(decision),
            .rejected(expected)
        )
        XCTAssertEqual(
            FileCapabilityPresentationState(decision),
            .disabled(expected)
        )
    }

    private var sourceCases: [SourceCase] {
        let webDAV = FileSourceID.remote(accountID: webDAVAccount, connectorID: .webDAV)
        let otherWebDAV = FileSourceID.remote(accountID: otherWebDAVAccount, connectorID: .webDAV)
        let kodbox = FileSourceID.remote(accountID: webDAVAccount, connectorID: .kodbox)
        let otherKodbox = FileSourceID.remote(accountID: kodboxAccount, connectorID: .kodbox)
        return [
            SourceCase(name: "Local", id: .local, expectedUnsupported: [:]),
            webDAVCase(name: "WebDAV-A", id: webDAV),
            webDAVCase(name: "WebDAV-B", id: otherWebDAV),
            kodboxCase(name: "Kodbox-A", id: kodbox),
            kodboxCase(name: "Kodbox-B", id: otherKodbox)
        ]
    }

    private func webDAVCase(name: String, id: FileSourceID) -> SourceCase {
        SourceCase(
            name: name,
            id: id,
            expectedUnsupported: [
                .tags: .operationUnsupported(sourceID: id, capability: .tags),
                .atomicPublish: .operationUnsupported(sourceID: id, capability: .atomicPublish)
            ]
        )
    }

    private func kodboxCase(name: String, id: FileSourceID) -> SourceCase {
        SourceCase(
            name: name,
            id: id,
            expectedUnsupported: [
                .atomicPublish: .operationUnsupported(sourceID: id, capability: .atomicPublish)
            ]
        )
    }
}

private struct SourceCase {
    let name: String
    let id: FileSourceID
    let expectedUnsupported: [FileCapability: FileCapabilityUnsupportedReason]
}
