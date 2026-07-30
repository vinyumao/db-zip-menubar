import XCTest
@testable import DbZipCore

final class RunFolderAllocatorTests: XCTestCase {
    func testStartsFrom01WhenEmpty() {
        let name = RunFolderAllocator.nextFolderName(existingNames: []) { _ in false }
        XCTAssertEqual(name, "01")
    }

    func testReusesMaxWhenEmpty() {
        let name = RunFolderAllocator.nextFolderName(existingNames: ["01", "02", "notes"]) { folder in
            folder == "02"
        }
        XCTAssertEqual(name, "02")
    }

    func testIncrementsWhenMaxNotEmpty() {
        let name = RunFolderAllocator.nextFolderName(existingNames: ["01", "02", "03"]) { _ in false }
        XCTAssertEqual(name, "04")
    }

    func testIgnoresNonNumericNames() {
        let name = RunFolderAllocator.nextFolderName(existingNames: ["abc", "v2", "09"]) { _ in false }
        XCTAssertEqual(name, "10")
    }

    func testLocalCopyAllocatesNumberedFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let fileA = srcDir.appendingPathComponent("a.txt")
        try "a".write(to: fileA, atomically: true, encoding: .utf8)

        let destBase = root.appendingPathComponent("dest", isDirectory: true)
        let service = LocalCopyService()

        let first = try service.copyCommonFiles([fileA], to: destBase)
        XCTAssertEqual(first.lastPathComponent, "01")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("a.txt").path))

        let second = try service.copyCommonFiles([fileA], to: destBase)
        XCTAssertEqual(second.lastPathComponent, "02")

        // 清空 02 后应复用
        try FileManager.default.removeItem(at: second.appendingPathComponent("a.txt"))
        let reused = try service.copyCommonFiles([fileA], to: destBase)
        XCTAssertEqual(reused.lastPathComponent, "02")
    }
}
