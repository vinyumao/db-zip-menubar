import XCTest
@testable import DbZipCore

final class CommonFilesCollectorTests: XCTestCase {
    func testCollectsLatestDBSIAndRecentFiveLogDayShards() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(root.appendingPathComponent("old.db"), contents: "a", date: Date(timeIntervalSince1970: 100))
        try write(root.appendingPathComponent("new.db"), contents: "b", date: Date(timeIntervalSince1970: 200))
        try write(root.appendingPathComponent("new.db-wal"), contents: "wal", date: Date(timeIntervalSince1970: 300))
        try write(root.appendingPathComponent("a.si"), contents: "s1", date: Date(timeIntervalSince1970: 50))
        try write(root.appendingPathComponent("b.si"), contents: "s2", date: Date(timeIntervalSince1970: 150))
        // 6 个不同日期：应取最近 5 天，丢掉最早的 20260101
        try write(root.appendingPathComponent("app_d20260101.log"), contents: "old", date: Date())
        try write(root.appendingPathComponent("app_d20260726.log"), contents: "d1", date: Date())
        try write(root.appendingPathComponent("app_d20260727.log"), contents: "d2", date: Date())
        try write(root.appendingPathComponent("app_d20260728.log"), contents: "d3", date: Date())
        try write(root.appendingPathComponent("app_d20260729.log"), contents: "d4", date: Date())
        try write(root.appendingPathComponent("app_d20260730.log"), contents: "d5", date: Date())
        try write(root.appendingPathComponent("app_d20260730_1.log"), contents: "d5b", date: Date())
        try write(root.appendingPathComponent("nested.txt"), contents: "x", date: Date())

        let result = try CommonFilesCollector.collect(in: root)
        XCTAssertEqual(result.dbFile?.lastPathComponent, "new.db")
        XCTAssertEqual(result.siFile?.lastPathComponent, "b.si")
        XCTAssertEqual(result.logDate, "20260730")
        XCTAssertEqual(
            Set(result.logFiles.map(\.lastPathComponent)),
            [
                "app_d20260726.log",
                "app_d20260727.log",
                "app_d20260728.log",
                "app_d20260729.log",
                "app_d20260730.log",
                "app_d20260730_1.log",
            ]
        )
        XCTAssertFalse(result.logFiles.contains { $0.lastPathComponent == "app_d20260101.log" })
        XCTAssertEqual(result.files.count, 9)
        XCTAssertTrue(result.files.contains { $0.lastPathComponent == "new.db-wal" })
    }

    func testEmptyWhenNoCommonFiles() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("readme.txt"), contents: "x", date: Date())
        let result = try CommonFilesCollector.collect(in: root)
        XCTAssertTrue(result.isEmpty)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, contents: String, date: Date) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
