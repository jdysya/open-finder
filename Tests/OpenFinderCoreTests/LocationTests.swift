import Foundation
import XCTest
@testable import OpenFinderCore

final class LocationTests: XCTestCase {
    func testLegacyWebDAVAndRcloneLocationsDecode() throws {
        let decoder = JSONDecoder()
        let webDAVID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let rcloneID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let webDAV = try decoder.decode(
            Location.self,
            from: Data("{\"type\":\"webDAV\",\"accountID\":\"\(webDAVID.uuidString)\",\"path\":\"/photos\"}".utf8)
        )
        let rclone = try decoder.decode(
            Location.self,
            from: Data("{\"type\":\"rclone\",\"remoteID\":\"\(rcloneID.uuidString)\",\"path\":\"remote:archive\"}".utf8)
        )

        XCTAssertEqual(webDAV, .webDAV(accountID: webDAVID, path: "/photos"))
        XCTAssertEqual(rclone, .rclone(remoteID: rcloneID, path: "remote:archive"))
    }

    func testLegacyLocationDecodeRejectsMalformedPayload() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Location.self,
                from: Data("{\"type\":\"webDAV\",\"accountID\":\"not-a-uuid\",\"path\":42}".utf8)
            )
        )
    }
}
