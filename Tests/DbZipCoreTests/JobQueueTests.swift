import XCTest
@testable import DbZipCore

final class JobQueueTests: XCTestCase {
    @MainActor
    func testReplacementRefreshesPendingIdentityButNeverReplacesActiveJob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("biz_123456789_1730000000000.zip")
        let store = PendingStore(appSupportDirectory: root)
        let queue = JobQueue(pendingStore: store, ignoreStore: IgnoreStore(appSupportDirectory: root))
        try Data("one".utf8).write(to: file)
        let first = try XCTUnwrap(queue.ingestDetected(url: file))
        XCTAssertNil(try queue.ingestDetected(url: file))
        try Data("replacement".utf8).write(to: file)
        let replacement = try XCTUnwrap(queue.ingestDetected(url: file))
        XCTAssertNotEqual(replacement.id, first.id)
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(replacement.identity, try FileIdentity(url: file))
        queue.begin(replacement)
        try Data("newer replacement".utf8).write(to: file)
        XCTAssertNil(try queue.ingestDetected(url: file))
        XCTAssertEqual(queue.pendingJobs.first?.id, replacement.id)
        XCTAssertEqual(PendingStore(appSupportDirectory: root).all().first?.id, replacement.id)
    }
}
