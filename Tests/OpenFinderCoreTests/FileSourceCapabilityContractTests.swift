import Foundation
import XCTest
@testable import OpenFinderCore

final class FileSourceCapabilityContractTests: XCTestCase {
    private let webDAVAccount = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherWebDAVAccount = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let kodboxAccount = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testProviderAndRelationalMatrix() {
        let local = FileSourceID.local
        let webDAV = FileSourceID.remote(accountID: webDAVAccount, connectorID: .webDAV)
        let kodbox = FileSourceID.remote(accountID: kodboxAccount, connectorID: .kodbox)

        assertSupported(
            FileSourceCapabilities(sourceID: local),
            [.list, .read, .create, .delete, .copy, .move, .tags, .materialize, .atomicPublish]
        )
        assertSupported(
            FileSourceCapabilities(sourceID: webDAV),
            [.list, .read, .create, .delete, .copy, .move, .materialize]
        )
        assertSupported(
            FileSourceCapabilities(sourceID: kodbox),
            [.list, .read, .create, .delete, .copy, .move, .tags, .materialize]
        )
        XCTAssertEqual(
            FileSourceCapabilities(sourceID: webDAV)[.tags],
            .unsupported(.operationUnsupported(sourceID: webDAV, capability: .tags))
        )
        XCTAssertEqual(
            FileSourceCapabilities(sourceID: webDAV)[.atomicPublish],
            .unsupported(.operationUnsupported(sourceID: webDAV, capability: .atomicPublish))
        )
        XCTAssertEqual(
            FileSourceCapabilities(sourceID: kodbox)[.atomicPublish],
            .unsupported(.operationUnsupported(sourceID: kodbox, capability: .atomicPublish))
        )

        XCTAssertEqual(
            FileRelationalCapabilities(source: webDAV, destination: webDAV).copy,
            .supported
        )
        XCTAssertEqual(
            FileRelationalCapabilities(source: webDAV, destination: webDAV).move,
            .supported
        )
        XCTAssertEqual(
            FileRelationalCapabilities(source: kodbox, destination: kodbox).copy,
            .supported
        )
        XCTAssertEqual(
            FileRelationalCapabilities(source: kodbox, destination: kodbox).move,
            .supported
        )
        XCTAssertEqual(
            FileRelationalCapabilities(source: webDAV, destination: webDAV, overwriteExisting: true).copy,
            .unsupported(.remoteOverwrite)
        )
        XCTAssertEqual(
            FileRelationalCapabilities(source: local, destination: local, overwriteExisting: true).copy,
            .supported
        )

        printMatrix("Local", capabilities: FileSourceCapabilities(sourceID: local))
        printMatrix("WebDAV", capabilities: FileSourceCapabilities(sourceID: webDAV))
        printMatrix("Kodbox", capabilities: FileSourceCapabilities(sourceID: kodbox))
        print("RELATION WebDAV same-account copy=supported move=supported overwrite=remoteOverwrite")
        print("RELATION Kodbox same-account copy=supported move=supported")
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

    private func assertSupported(
        _ capabilities: FileSourceCapabilities,
        _ expected: Set<FileCapability>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for capability in FileCapability.allCases {
            XCTAssertEqual(
                capabilities[capability].isSupported,
                expected.contains(capability),
                "\(capabilities.sourceID) \(capability)",
                file: file,
                line: line
            )
        }
    }

    private func printMatrix(_ name: String, capabilities: FileSourceCapabilities) {
        let values = FileCapability.allCases.map {
            "\($0.rawValue)=\(capabilities[$0].isSupported ? "supported" : "unsupported")"
        }
        print("MATRIX \(name) \(values.joined(separator: " "))")
    }
}
