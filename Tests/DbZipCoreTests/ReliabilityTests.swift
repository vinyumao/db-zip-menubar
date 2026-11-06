import XCTest
@testable import DbZipCore

final class ReliabilityTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dbzip-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func zip(_ name: String, file: String, text: String) throws -> URL {
        let input = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try text.write(to: input.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent(name)
        let result = try FoundationProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", input.path, archive.path])
        XCTAssertEqual(result.exitCode, 0)
        return archive
    }

    func testUnpackFailureKeepsSourceAndRetrySucceeds() throws {
        let archive = try zip("data.zip", file: "a.db", text: "data")
        let runner = FailOnceRunner()
        let service = UnpackService(processRunner: runner)
        let output = root.appendingPathComponent("output")
        XCTAssertThrowsError(try service.unpack(zipURL: archive, dbRoot: output))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let result = try service.unpack(zipURL: archive, dbRoot: output)
        XCTAssertEqual(try String(contentsOf: result.extractDirectory.appendingPathComponent("a.db")), "data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testSameNameArchivesNeverMerge() throws {
        let output = root.appendingPathComponent("output")
        let first = try UnpackService().unpack(zipURL: zip("data.zip", file: "old.db", text: "old"), dbRoot: output)
        let second = try UnpackService().unpack(zipURL: zip("data.zip", file: "new.db", text: "new"), dbRoot: output)
        XCTAssertNotEqual(first.extractDirectory, second.extractDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second.extractDirectory.path), ["new.db"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.extractDirectory.appendingPathComponent("old.db").path))
    }

    func testCorruptArchivePreservedAndNoPublishedDirectory() throws {
        let archive = root.appendingPathComponent("broken.zip")
        try Data("broken".utf8).write(to: archive)
        let output = root.appendingPathComponent("output")
        XCTAssertThrowsError(try UnpackService().unpack(zipURL: archive, dbRoot: output))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let day = output.appendingPathComponent(UnpackService.dayFolderName(date: Date()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: day.path).isEmpty)
    }

    func testProcessDrainsLargeStdoutAndStderr() throws {
        let result = try FoundationProcessRunner(timeout: 10, outputLimit: 4 * 1024 * 1024).run(
            executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for(i=0;i<100000;i++) { print \"abcdefghijklmnop\"; print \"qrstuvwxyz012345\" > \"/dev/stderr\" } }"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 1_700_000)
        XCTAssertEqual(result.stderr.utf8.count, 1_700_000)
    }

    func testProcessTimeoutAndCancellation() throws {
        let start = Date()
        XCTAssertThrowsError(try FoundationProcessRunner(timeout: 0.1).run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"])) {
            guard case OperationError.timedOut = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let control = OperationControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { control.cancel() }
        XCTAssertThrowsError(try FoundationProcessRunner(control: control).run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"])) {
            guard case OperationError.cancelled = $0 else { return XCTFail("\($0)") }
        }
    }

    func testCancelledCopyLeavesNoPartialNumberedFolder() throws {
        let file = root.appendingPathComponent("a.db")
        try Data("db".utf8).write(to: file)
        let output = root.appendingPathComponent("output")
        let control = OperationControl()
        control.cancel()
        XCTAssertThrowsError(try LocalCopyService().copyFiles([file], to: output, control: control))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    func testCopyRejectsRecursiveDestinationAndSymlinks() throws {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertThrowsError(try LocalCopyService().copyFiles([source], to: source.appendingPathComponent("nested")))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try FileManifest.entries(at: link))
    }

    @MainActor
    func testPreviewRequiresConfirmationAndRecordsOutcome() async throws {
        let archive = try zip("biz_123456789_1730000000000.zip", file: "a.db", text: "db")
        let output = root.appendingPathComponent("destination")
        let extracts = ExtractHistoryStore(appSupportDirectory: root)
        let history = HistoryStore(appSupportDirectory: root, legacyHistoryURL: root.appendingPathComponent("none"))
        let coordinator = WizardCoordinator(job: PendingJob(identity: try FileIdentity(url: archive), fileName: archive.lastPathComponent),
            settings: AppSettings(dbRootDirectory: root.appendingPathComponent("unpacked").path), history: history,
            extractHistory: extracts, makeAdb: { AdbClient() })
        await coordinator.startUnpack()
        XCTAssertEqual(coordinator.step, .chooseDestination)
        coordinator.chooseDestination(.path)
        coordinator.selectPath(output.path, typed: true)
        await coordinator.chooseContentMode(.common)
        XCTAssertEqual(coordinator.step, .preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        await coordinator.confirmPreview()
        XCTAssertEqual(coordinator.step, .success)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("01/a.db")), "db")
        XCTAssertEqual(extracts.list().first?.status, "成功")
    }
}

private final class FailOnceRunner: ProcessRunning {
    var failed = false
    func run(executable: URL, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        if arguments.first == "-x", !failed { failed = true; return (1, "", "simulated failure") }
        return try FoundationProcessRunner().run(executable: executable, arguments: arguments)
    }
}
