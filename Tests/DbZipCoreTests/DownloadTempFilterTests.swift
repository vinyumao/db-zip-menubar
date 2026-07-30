import XCTest
@testable import DbZipCore

final class DownloadTempFilterTests: XCTestCase {
    func testIgnoresBrowserTempNames() {
        XCTAssertTrue(DownloadTempFilter.isTemporaryName("a.zip.crdownload"))
        XCTAssertTrue(DownloadTempFilter.isTemporaryName("a.zip.download"))
        XCTAssertTrue(DownloadTempFilter.isTemporaryName(".partial.zip"))
        XCTAssertTrue(DownloadTempFilter.isTemporaryName("file.part"))
    }

    func testAllowsFinishedZip() {
        XCTAssertFalse(DownloadTempFilter.isTemporaryName("shop_123456789_x_1710000000.zip"))
        XCTAssertTrue(DownloadTempFilter.isCandidateZipName("shop_123456789_x_1710000000.zip"))
    }
}
