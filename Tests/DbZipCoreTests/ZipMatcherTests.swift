import XCTest
@testable import DbZipCore

final class ZipMatcherTests: XCTestCase {
    func testAcceptsTypicalBusinessZip() {
        let name = "shop_123456789_backup_1710000000.zip"
        XCTAssertTrue(ZipMatcher.isTargetZip(name))
        XCTAssertNil(ZipMatcher.mismatchReason(for: name))
    }

    func testRejectsInsufficientUnderscores() {
        XCTAssertFalse(ZipMatcher.isTargetZip("123456789_1710000000.zip"))
    }

    func testRejectsMissingNineDigitSegment() {
        XCTAssertFalse(ZipMatcher.isTargetZip("shop_12345678_backup_1710000000.zip"))
    }

    func testRejectsMissingTimestamp() {
        XCTAssertFalse(ZipMatcher.isTargetZip("shop_123456789_backup.zip"))
    }

    func testZipSuffixIsCaseInsensitive() {
        XCTAssertTrue(ZipMatcher.isTargetZip("shop_123456789_backup_1710000000.ZIP"))
    }
}
