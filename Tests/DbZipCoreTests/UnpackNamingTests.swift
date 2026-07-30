import XCTest
@testable import DbZipCore

final class UnpackNamingTests: XCTestCase {
    func testDayAndTimeFormats() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let date = Date(timeIntervalSince1970: 1_753_833_600) // 2025-07-30 00:00:00 GMT+8 approx — verify via formatter
        let day = UnpackService.dayFolderName(date: date, calendar: calendar)
        XCTAssertEqual(day.count, 8)
        let suffix = UnpackService.timeSuffix(date: date, calendar: calendar)
        XCTAssertEqual(suffix.count, 6)
    }
}
