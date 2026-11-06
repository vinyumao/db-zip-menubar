import XCTest
@testable import DbZipCore

final class AdbPushStagingTests: XCTestCase {
    private var tempFile: URL!
    override func setUpWithError() throws {
        tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("adb-staging-" + UUID().uuidString + ".txt")
        try "probe".write(to: tempFile, atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempFile) }

    func testLivePushOnD4IfPresent() throws {
        guard ProcessInfo.processInfo.environment["DBZIP_LIVE_ADB_TESTS"] == "1" else {
            throw XCTSkip("Set DBZIP_LIVE_ADB_TESTS=1 to opt into device writes")
        }
        let sn = ProcessInfo.processInfo.environment["DBZIP_TEST_DEVICE"] ?? "ND4X504E3308C0075"
        let runner = FoundationProcessRunner()
        let client = AdbClient()
        guard let adb = client.resolveAdbURL() else {
            throw XCTSkip("adb not found")
        }
        let devices = try runner.run(executable: adb, arguments: ["devices"])
        guard devices.stdout.contains(sn) else {
            throw XCTSkip("D4 (\(sn)) not connected")
        }

        try client.push(
            sn: sn,
            localURL: tempFile,
            remoteDir: AdbPaths.preferredRemoteDir
        )

        let remote = "\(AdbPaths.preferredRemoteDir)/\(tempFile.lastPathComponent)"
        defer { _ = try? runner.run(executable: adb, arguments: ["-s", sn, "shell", "rm -f " + AdbClient.shellQuote(remote)]) }
        let ls = try runner.run(
            executable: adb,
            arguments: ["-s", sn, "shell", "cat \"\(remote)\""]
        )
        XCTAssertTrue(ls.stdout.contains("probe"), ls.stdout)
        _ = try runner.run(executable: adb, arguments: ["-s", sn, "shell", "rm -f \"\(remote)\""])

        let leftover = try runner.run(
            executable: adb,
            arguments: [
                "-s", sn, "shell",
                "ls \"\(AdbPaths.fallbackRemoteDir)/\(tempFile.lastPathComponent)\" 2>&1 || echo GONE"
            ]
        )
        XCTAssertTrue(
            leftover.stdout.contains("No such file") || leftover.stdout.contains("GONE"),
            leftover.stdout
        )
    }
}
