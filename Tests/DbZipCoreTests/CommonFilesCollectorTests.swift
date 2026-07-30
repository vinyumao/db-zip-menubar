import XCTest
@testable import DbZipCore

final class CommonFilesCollectorTests: XCTestCase {
    func testCollectsLatestDBSIAndNewestLogDayShards() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(root.appendingPathComponent("old.db"), contents: "a", date: Date(timeIntervalSince1970: 100))
        try write(root.appendingPathComponent("new.db"), contents: "b", date: Date(timeIntervalSince1970: 200))
        try write(root.appendingPathComponent("new.db-wal"), contents: "wal", date: Date(timeIntervalSince1970: 300))
        try write(root.appendingPathComponent("a.si"), contents: "s1", date: Date(timeIntervalSince1970: 50))
        try write(root.appendingPathComponent("b.si"), contents: "s2", date: Date(timeIntervalSince1970: 150))
        try write(root.appendingPathComponent("app_d20260101.log"), contents: "l1", date: Date())
        try write(root.appendingPathComponent("app_d20260730.log"), contents: "l2", date: Date())
        try write(root.appendingPathComponent("app_d20260730_1.log"), contents: "l3", date: Date())
        try write(root.appendingPathComponent("nested.txt"), contents: "x", date: Date())

        let result = try CommonFilesCollector.collect(in: root)
        XCTAssertEqual(result.dbFile?.lastPathComponent, "new.db")
        XCTAssertEqual(result.siFile?.lastPathComponent, "b.si")
        XCTAssertEqual(result.logDate, "20260730")
        XCTAssertEqual(Set(result.logFiles.map(\.lastPathComponent)), ["app_d20260730.log", "app_d20260730_1.log"])
        XCTAssertEqual(result.files.count, 4)
        XCTAssertFalse(result.files.contains { $0.lastPathComponent == "new.db-wal" })
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
