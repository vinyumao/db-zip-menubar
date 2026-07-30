import XCTest
@testable import DbZipCore

final class DbRootCleanupTests: XCTestCase {
    func testShouldDeleteScopes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 30))!

        XCTAssertTrue(DbRootCleanup.shouldDelete(folderName: "20260730", scope: .today, now: now, calendar: calendar))
        XCTAssertFalse(DbRootCleanup.shouldDelete(folderName: "20260729", scope: .today, now: now, calendar: calendar))

        XCTAssertTrue(DbRootCleanup.shouldDelete(folderName: "20260729", scope: .olderThanOneDay, now: now, calendar: calendar))
        XCTAssertFalse(DbRootCleanup.shouldDelete(folderName: "20260730", scope: .olderThanOneDay, now: now, calendar: calendar))

        XCTAssertTrue(DbRootCleanup.shouldDelete(folderName: "20260722", scope: .olderThanOneWeek, now: now, calendar: calendar))
        XCTAssertFalse(DbRootCleanup.shouldDelete(folderName: "20260723", scope: .olderThanOneWeek, now: now, calendar: calendar))

        XCTAssertTrue(DbRootCleanup.shouldDelete(folderName: "20260629", scope: .olderThanOneMonth, now: now, calendar: calendar))
        XCTAssertFalse(DbRootCleanup.shouldDelete(folderName: "20260630", scope: .olderThanOneMonth, now: now, calendar: calendar))

        XCTAssertTrue(DbRootCleanup.shouldDelete(folderName: "20260101", scope: .all, now: now, calendar: calendar))
        XCTAssertFalse(DbRootCleanup.isDayFolderName("notes"))
    }

    func testPlanOnlyPicksDayFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("20260101"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("20260730"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("misc"), withIntermediateDirectories: true)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 30))!

        let plan = try DbRootCleanup.plan(dbRoot: root, scope: .all, now: now, calendar: calendar)
        XCTAssertEqual(Set(plan.folders.map(\.lastPathComponent)), ["20260101", "20260730"])
    }
}
