import XCTest
@testable import DbZipCore

final class ExtractHistoryStoreTests: XCTestCase {
    func testRecordListsNewestFirstAndDropsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keep = root.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("missing", isDirectory: true)

        let store = ExtractHistoryStore(appSupportDirectory: root)
        store.record(extractPath: missing.path, sourceFileName: "gone.zip")
        store.record(extractPath: keep.path, sourceFileName: "keep.zip")

        let listed = store.list(existingOnly: true)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.sourceFileName, "keep.zip")
    }

    func testKeepsAtMostTenAndValidateRemovesMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ExtractHistoryStore(appSupportDirectory: root)
        var dirs: [URL] = []
        for i in 1...12 {
            let dir = root.appendingPathComponent("e\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dirs.append(dir)
            store.record(extractPath: dir.path, sourceFileName: "f\(i).zip")
        }

        let listed = store.list()
        XCTAssertEqual(listed.count, 10)
        XCTAssertEqual(listed.first?.sourceFileName, "f12.zip")
        XCTAssertFalse(listed.contains { $0.sourceFileName == "f1.zip" || $0.sourceFileName == "f2.zip" })

        let victim = listed[0]
        try FileManager.default.removeItem(at: victim.extractURL)
        XCTAssertFalse(store.validateAndKeep(victim))
        XCTAssertEqual(store.list().count, 9)
    }
}
