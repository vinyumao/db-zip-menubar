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

    func testAcceptsUploadLogZip() {
        for name in [
            "upload_log_xx_yy_A49C002B00900013_1793771967067.zip",
            "upload_log_门店_收银机_OTHERDEVICE_1793771967068.ZIP"
        ] {
            XCTAssertTrue(ZipMatcher.isTargetZip(name), name)
            XCTAssertNil(ZipMatcher.mismatchReason(for: name), name)
        }
    }

    func testRejectsMalformedUploadLogZip() {
        for name in [
            "upload_log__yy_A49C002B00900013_1793771967067.zip",
            "upload_log_xx__A49C002B00900013_1793771967067.zip",
            "upload_log_xx_yy__1793771967067.zip",
            "upload_log_xx_yy_A49C002B00900013.zip",
            "upload_log_xx_yy_A49C002B00900013_179377196.zip",
            "upload_log_xx_yy_A49C002B00900013_179377196706x.zip",
            "upload_log_xx_yy_A49C002B00900013_1793771967067.zip.download",
            "backup_xx_yy_A49C002B00900013_1793771967067.zip"
        ] {
            XCTAssertFalse(ZipMatcher.isTargetZip(name), name)
            XCTAssertNotNil(ZipMatcher.mismatchReason(for: name), name)
        }
    }
}
