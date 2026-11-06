import XCTest
@testable import DbZipCore

final class ContentPlanTests: XCTestCase {
    func testWrapperWALPairAndLogDateSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let wrapped = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: wrapped, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.db", "a.db-wal", "a.db-shm", "app_d20261106.log", "app_d20261106.1.log", "app_d20261105.log"] {
            try Data("x".utf8).write(to: wrapped.appendingPathComponent(name))
        }
        let plan = try ContentPlanner.make(root: root, mode: .common, logDays: 1)
        XCTAssertEqual(plan.root.resolvingSymlinksInPath().path, wrapped.resolvingSymlinksInPath().path)
        XCTAssertEqual(plan.items.count, 5)
        XCTAssertEqual(plan.totalBytes, 5)
        XCTAssertEqual(plan.warnings.count, 2)
        var ids = Set(plan.items.map(\.id))
        XCTAssertEqual(try plan.selectedFiles(ids: ids).count, 5)
        let walID = try XCTUnwrap(plan.items.first { $0.url.lastPathComponent == "a.db-wal" }).id
        ids.remove(walID)
        XCTAssertThrowsError(try plan.selectedFiles(ids: ids))
        XCTAssertThrowsError(try plan.selectedFiles(ids: [walID]))
    }

    @MainActor
    func testPresetPersistenceReplacementAndRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PresetStore(appSupportDirectory: root)
        let preset = ProcessingPreset(name: "分析", kind: .path, mode: .common, path: "/tmp/analysis", device: nil, logDays: 3)
        try store.save(preset)
        XCTAssertEqual(PresetStore(appSupportDirectory: root).presets, [preset])
        var replacement = preset
        replacement.logDays = 7
        try store.save(replacement)
        XCTAssertEqual(store.presets.count, 1)
        XCTAssertEqual(store.presets[0].logDays, 7)
        try store.remove(id: preset.id)
        XCTAssertTrue(PresetStore(appSupportDirectory: root).presets.isEmpty)
    }
}
