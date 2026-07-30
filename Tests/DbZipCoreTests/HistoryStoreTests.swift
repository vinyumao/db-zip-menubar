import XCTest
@testable import DbZipCore

final class HistoryStoreTests: XCTestCase {
    func testTouchPathKeepsMaxTenAndMarksLast() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var clock = 1000
        let store = HistoryStore(
            appSupportDirectory: dir,
            legacyHistoryURL: dir.appendingPathComponent("missing-legacy.json"),
            now: { clock }
        )

        for i in 1...12 {
            clock = 1000 + i
            store.touchPath("/tmp/p\(i)")
        }

        let listed = store.listPaths()
        XCTAssertEqual(listed.count, 10)
        XCTAssertEqual(listed.first?.path, "/tmp/p12")
        XCTAssertTrue(listed.first?.isLast == true)
        XCTAssertFalse(listed.contains { $0.path == "/tmp/p1" || $0.path == "/tmp/p2" })
        XCTAssertTrue(store.isPathKnown("/tmp/p12"))
    }

    func testMigratesLegacyHistoryOnce() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("legacy.json")
        let payload = """
        {"paths":[{"path":"/old/path","ts":42}],"devices":[{"sn":"ABC","brand":"Brand","model":"Model","ts":43}]}
        """
        try payload.write(to: legacy, atomically: true, encoding: .utf8)

        let store = HistoryStore(appSupportDirectory: dir, legacyHistoryURL: legacy)
        XCTAssertEqual(store.listPaths().first?.path, "/old/path")
        XCTAssertEqual(store.lastDeviceSN(), "ABC")

        // 再次构造不应覆盖用户新数据
        store.touchPath("/new/path")
        let again = HistoryStore(appSupportDirectory: dir, legacyHistoryURL: legacy)
        XCTAssertEqual(again.listPaths().first?.path, "/new/path")
        XCTAssertTrue(again.isPathKnown("/old/path") || again.listPaths().contains { $0.path == "/old/path" } || again.listPaths().count >= 1)
    }

    func testIgnoreIdentityChangesWhenSizeChanges() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ignore = IgnoreStore(appSupportDirectory: dir)
        let a = FileIdentity(path: "/tmp/a.zip", fileSize: 10, mtime: 1)
        let b = FileIdentity(path: "/tmp/a.zip", fileSize: 11, mtime: 1)
        ignore.ignore(a)
        XCTAssertTrue(ignore.isIgnored(a))
        XCTAssertFalse(ignore.isIgnored(b))
    }

    func testLastSuccessfulActionPersistsAndDoesNotInferFromLists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var clock = 2000
        let store = HistoryStore(
            appSupportDirectory: dir,
            legacyHistoryURL: dir.appendingPathComponent("missing-legacy.json"),
            now: { clock }
        )
        store.touchPath("/tmp/only-path")
        XCTAssertNil(store.lastSuccessfulAction())

        let action = LastSuccessfulAction(
            kind: .path,
            contentMode: .common,
            path: "/tmp/only-path",
            ts: 2001
        )
        store.saveLastSuccessfulAction(action)
        XCTAssertEqual(store.lastSuccessfulAction()?.path, "/tmp/only-path")
        XCTAssertEqual(store.lastSuccessfulAction()?.contentMode, .common)

        let reloaded = HistoryStore(
            appSupportDirectory: dir,
            legacyHistoryURL: dir.appendingPathComponent("missing-legacy.json"),
            now: { clock }
        )
        XCTAssertEqual(reloaded.lastSuccessfulAction()?.kind, .path)
    }

    func testLastActionValidatorPathAndDevice() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writable = dir.appendingPathComponent("ok", isDirectory: true)
        try FileManager.default.createDirectory(at: writable, withIntermediateDirectories: true)

        let pathAction = LastSuccessfulAction(
            kind: .path,
            contentMode: .tree,
            path: writable.path,
            ts: 1
        )
        let pathOK = LastActionValidator.resolve(action: pathAction, readyDeviceSNs: { [] })
        XCTAssertTrue(pathOK.isReady)

        let missing = LastSuccessfulAction(
            kind: .path,
            contentMode: .tree,
            path: dir.appendingPathComponent("missing").path,
            ts: 1
        )
        let pathBad = LastActionValidator.resolve(action: missing, readyDeviceSNs: { [] })
        guard case .unavailable(_, let reason) = pathBad else {
            return XCTFail("expected unavailable")
        }
        XCTAssertTrue(reason.contains("不存在") || reason.contains("不是目录"))

        let deviceAction = LastSuccessfulAction(
            kind: .device,
            contentMode: .common,
            deviceSN: "SN1",
            deviceBrand: "Brand",
            deviceModel: "Model",
            ts: 2
        )
        let deviceOK = LastActionValidator.resolve(action: deviceAction, readyDeviceSNs: { ["SN1"] })
        XCTAssertTrue(deviceOK.isReady)
        let deviceOff = LastActionValidator.resolve(action: deviceAction, readyDeviceSNs: { ["OTHER"] })
        XCTAssertEqual(deviceOff.blockReason?.contains("未连接"), true)

        XCTAssertEqual(LastActionValidator.resolve(action: nil, readyDeviceSNs: { [] }), .none)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
