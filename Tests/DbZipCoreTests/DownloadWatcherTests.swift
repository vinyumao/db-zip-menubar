import XCTest
@testable import DbZipCore

private final class WatchProbe: DownloadWatcherDelegate {
    var handler: (() -> Void)?
    func downloadWatcher(didDetectStableZip url: URL) { handler?() }
}

final class DownloadWatcherTests: XCTestCase {
    @MainActor
    func testRecreatedPathAndRestartAreDetected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("biz_123456789_1730000000000.zip")
        let watcher = DownloadWatcher(stabilitySeconds: 0.1)
        let probe = WatchProbe()
        watcher.delegate = probe
        watcher.start(directory: root, confirmedAccess: true)
        XCTAssertTrue(watcher.isWatching())
        defer { watcher.stop() }
        for iteration in 0..<3 {
            let detected = expectation(description: "detection \(iteration)")
            detected.assertForOverFulfill = true
            probe.handler = { detected.fulfill() }
            try Data(String(repeating: "x", count: iteration + 1).utf8).write(to: file)
            await fulfillment(of: [detected], timeout: 5)
            probe.handler = nil
            try FileManager.default.removeItem(at: file)
            try await Task.sleep(for: .milliseconds(200))
            if iteration == 1 {
                watcher.start(directory: root, confirmedAccess: true)
                XCTAssertTrue(watcher.isWatching())
            }
        }
    }

    @MainActor
    func testColdStartDoesNotEnqueueExistingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("existing".utf8).write(to: root.appendingPathComponent("existing.zip"))
        let ignored = expectation(description: "existing file must remain ignored")
        ignored.isInverted = true
        let watcher = DownloadWatcher(stabilitySeconds: 0.1)
        let probe = WatchProbe()
        probe.handler = { ignored.fulfill() }
        watcher.delegate = probe
        watcher.start(directory: root, confirmedAccess: true)
        XCTAssertTrue(watcher.isWatching())
        await fulfillment(of: [ignored], timeout: 1.5)
        watcher.stop()
    }
}
