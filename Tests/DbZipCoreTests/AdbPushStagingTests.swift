import XCTest
@testable import DbZipCore

private final class RecordingProcessRunner: ProcessRunning {
    private(set) var argumentLists: [[String]] = []
    var results: [(exitCode: Int32, stdout: String, stderr: String)] = []
    private var index = 0

    func run(executable: URL, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        argumentLists.append(arguments)
        if index < results.count {
            defer { index += 1 }
            return results[index]
        }
        return (0, "", "")
    }
}

final class AdbPushStagingTests: XCTestCase {
    private var tempFile: URL!

    override func setUpWithError() throws {
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("adb-staging-\(UUID().uuidString).txt")
        try "probe".write(to: tempFile, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFile)
    }

    func testPushToPreferredUsesStagingThenCp() throws {
        let runner = RecordingProcessRunner()
        runner.results = [
            (0, "__MKDIR_OK__\n", ""), // mkdir /sdcard/db
            (0, "", ""), // adb push → staging
            (0, "__CP_OK__\n", "") // shell cp + rm
        ]
        let client = AdbClient(configuredPath: "/usr/bin/true", processRunner: runner)

        try client.push(
            sn: "ND4X504E3308C0075",
            localURL: tempFile,
            remoteDir: AdbPaths.preferredRemoteDir
        )

        XCTAssertEqual(runner.argumentLists.count, 3)

        let mkdirArgs = runner.argumentLists[0]
        XCTAssertEqual(mkdirArgs[0], "-s")
        XCTAssertEqual(mkdirArgs[1], "ND4X504E3308C0075")
        XCTAssertEqual(mkdirArgs[2], "shell")
        XCTAssertTrue(mkdirArgs[3].contains(AdbPaths.fallbackRemoteDir))

        let pushArgs = runner.argumentLists[1]
        XCTAssertEqual(pushArgs[2], "push")
        XCTAssertEqual(pushArgs[3], tempFile.path)
        XCTAssertEqual(
            pushArgs[4],
            "\(AdbPaths.fallbackRemoteDir)/\(tempFile.lastPathComponent)"
        )

        let cpArgs = runner.argumentLists[2]
        XCTAssertEqual(cpArgs[2], "shell")
        let cmd = cpArgs[3]
        XCTAssertTrue(cmd.contains("cp "))
        XCTAssertTrue(cmd.contains("chmod 660"))
        XCTAssertTrue(cmd.contains("\(AdbPaths.fallbackRemoteDir)/\(tempFile.lastPathComponent)"))
        XCTAssertTrue(cmd.contains("\(AdbPaths.preferredRemoteDir)/\(tempFile.lastPathComponent)"))
        XCTAssertTrue(cmd.contains("rm "))
    }

    func testPushToFallbackIsDirect() throws {
        let runner = RecordingProcessRunner()
        runner.results = [
            (0, "", "") // direct push only
        ]
        let client = AdbClient(configuredPath: "/usr/bin/true", processRunner: runner)

        try client.push(
            sn: "ND4X504E3308C0075",
            localURL: tempFile,
            remoteDir: AdbPaths.fallbackRemoteDir
        )

        XCTAssertEqual(runner.argumentLists.count, 1)
        let pushArgs = runner.argumentLists[0]
        XCTAssertEqual(pushArgs[2], "push")
        XCTAssertEqual(
            pushArgs[4],
            "\(AdbPaths.fallbackRemoteDir)/\(tempFile.lastPathComponent)"
        )
    }

    func testPushThrowsWhenCpFails() throws {
        let runner = RecordingProcessRunner()
        runner.results = [
            (0, "__MKDIR_OK__\n", ""),
            (0, "", ""),
            (1, "", "cp: Permission denied")
        ]
        let client = AdbClient(configuredPath: "/usr/bin/true", processRunner: runner)

        XCTAssertThrowsError(
            try client.push(
                sn: "SN",
                localURL: tempFile,
                remoteDir: AdbPaths.preferredRemoteDir
            )
        ) { error in
            guard case AdbError.pushFailed(let message) = error else {
                return XCTFail("expected pushFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("Permission denied"))
        }
    }

    func testLivePushOnD4IfPresent() throws {
        let sn = "ND4X504E3308C0075"
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
