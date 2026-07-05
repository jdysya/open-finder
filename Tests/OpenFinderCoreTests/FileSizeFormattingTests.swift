import XCTest
@testable import OpenFinderCore

final class FileSizeFormattingTests: XCTestCase {
    func testFormatsSizesWithDecimalKBMBGBThresholds() {
        XCTAssertEqual(FileSizeFormatter.openFinderString(fromByteCount: 0), "0 KB")
        XCTAssertEqual(FileSizeFormatter.openFinderString(fromByteCount: 512), "1 KB")
        XCTAssertEqual(FileSizeFormatter.openFinderString(fromByteCount: 999_000), "999 KB")
        XCTAssertEqual(FileSizeFormatter.openFinderString(fromByteCount: 1_500_000), "1.5 MB")
        XCTAssertEqual(FileSizeFormatter.openFinderString(fromByteCount: 999_000_000), "999 MB")
        XCTAssertEqual(FileSizeFormatter.openFinderString(fromByteCount: 999_999_999), "999.9 MB")
        XCTAssertEqual(FileSizeFormatter.openFinderString(fromByteCount: 1_500_000_000), "1.5 GB")
        XCTAssertEqual(FileSizeFormatter.openFinderString(fromByteCount: 999_999_999_999), "999.9 GB")
    }
}
