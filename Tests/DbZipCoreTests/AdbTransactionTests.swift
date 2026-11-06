import XCTest
@testable import DbZipCore

private final class SandboxedAdbRunner: ProcessRunning {
    let root: URL
    var failAfterBackup = false
    var corruptUpload = false
    var pushedPaths: [String] = []
    init(root: URL) { self.root = root }
    func run(executable: URL, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        func local(_ text: String) -> String {
            text.replacingOccurrences(of: "/sdcard/db", with: root.appendingPathComponent("staging").path)
                .replacingOccurrences(of: "/test-target", with: root.appendingPathComponent("target").path)
        }
        if arguments[2] == "push" {
            pushedPaths.append(arguments[4])
            let target = URL(fileURLWithPath: local(arguments[4]))
            try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[3]), to: target)
            if corruptUpload { try Data("bad".utf8).write(to: target) }
            return (0, "", "")
        }
        var command = local(arguments[3])
        if failAfterBackup, command.contains("__COMMITTED__") {
            command = String(command.split(separator: "\n")[0]) + "\nexit 1"
        }
        return try FoundationProcessRunner(timeout: 10).run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command])
    }
}

final class AdbTransactionTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("adb-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func prepare(name: String = "a.db") throws -> (URL, URL) {
        let input = root.appendingPathComponent("input")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let source = input.appendingPathComponent(name)
        let old = target.appendingPathComponent(name)
        try "new contents".write(to: source, atomically: true, encoding: .utf8)
        try "old contents".write(to: old, atomically: true, encoding: .utf8)
        return (source, old)
    }

    func testVerifiedReplacementQuotesFilenamesAndCleansStaging() throws {
        let (source, target) = try prepare(name: "a'$(printf injected) space.db")
        let runner = SandboxedAdbRunner(root: root)
        let client = AdbClient(configuredPath: "/usr/bin/true", processRunner: runner)
        try client.push(sn: "fake", localURL: source, remoteDir: "/test-target")
        XCTAssertEqual(try String(contentsOf: target), "new contents")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("target").path), [source.lastPathComponent])
        try client.push(sn: "fake", localURL: source, remoteDir: "/test-target")
        XCTAssertNotEqual(runner.pushedPaths[0], runner.pushedPaths[1])
    }

    func testCommitFailureRestoresPreviousTarget() throws {
        let (source, target) = try prepare()
        let runner = SandboxedAdbRunner(root: root)
        runner.failAfterBackup = true
        let client = AdbClient(configuredPath: "/usr/bin/true", processRunner: runner)
        XCTAssertThrowsError(try client.push(sn: "fake", localURL: source, remoteDir: "/test-target"))
        XCTAssertEqual(try String(contentsOf: target), "old contents")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("target").path), [source.lastPathComponent])
    }

    func testVerificationFailureNeverReplacesPreviousTarget() throws {
        let (source, target) = try prepare()
        let runner = SandboxedAdbRunner(root: root)
        runner.corruptUpload = true
        XCTAssertThrowsError(try AdbClient(configuredPath: "/usr/bin/true", processRunner: runner).push(sn: "fake", localURL: source, remoteDir: "/test-target"))
        XCTAssertEqual(try String(contentsOf: target), "old contents")
    }

    func testDirectoryReplacementRemovesStaleChildrenOnlyAfterVerification() throws {
        let source = root.appendingPathComponent("input/logs")
        let target = root.appendingPathComponent("target/logs")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "fresh".write(to: source.appendingPathComponent("nested/new.log"), atomically: true, encoding: .utf8)
        try "old".write(to: target.appendingPathComponent("old.log"), atomically: true, encoding: .utf8)
        let runner = SandboxedAdbRunner(root: root)
        try AdbClient(configuredPath: "/usr/bin/true", processRunner: runner).push(sn: "fake", localURL: source, remoteDir: "/test-target")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("nested/new.log")), "fresh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("old.log").path))
    }
}
