import Foundation

public struct AppPaths {
    public static let appSupportFolderName = "db-zip-menubar"

    public static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appSupportFolderName, isDirectory: true)
    }
}

public enum UnpackError: LocalizedError, Sendable {
    case sourceMissing(URL)
    case createDirectoryFailed(URL, String)
    case moveFailed(URL, URL, String)
    case extractFailed(String)
    case deleteZipFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let url):
            return "源 zip 不存在: \(url.path)"
        case .createDirectoryFailed(let url, let message):
            return "创建目录失败 \(url.path): \(message)"
        case .moveFailed(let from, let to, let message):
            return "移动失败 \(from.lastPathComponent) → \(to.path): \(message)"
        case .extractFailed(let message):
            return "解压失败: \(message)"
        case .deleteZipFailed(let url, let message):
            return "删除 zip 失败 \(url.path): \(message)"
        }
    }
}

public struct UnpackResult: Sendable, Equatable {
    public var extractDirectory: URL
    public var movedZip: URL

    public init(extractDirectory: URL, movedZip: URL) {
        self.extractDirectory = extractDirectory
        self.movedZip = movedZip
    }
}

public protocol ProcessRunning {
    @discardableResult
    func run(executable: URL, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String)
}

public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}

public struct UnpackService {
    private let fileManager: FileManager
    private let processRunner: any ProcessRunning
    private let dateProvider: () -> Date
    private let openFinder: (URL) -> Void

    public init(
        fileManager: FileManager = .default,
        processRunner: any ProcessRunning = FoundationProcessRunner(),
        dateProvider: @escaping () -> Date = { Date() },
        openFinder: @escaping (URL) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.processRunner = processRunner
        self.dateProvider = dateProvider
        self.openFinder = openFinder
    }

    public func unpack(zipURL: URL, dbRoot: URL) throws -> UnpackResult {
        guard fileManager.fileExists(atPath: zipURL.path) else {
            throw UnpackError.sourceMissing(zipURL)
        }

        let day = Self.dayFolderName(date: dateProvider())
        let targetDir = dbRoot.appendingPathComponent(day, isDirectory: true)
        do {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            throw UnpackError.createDirectoryFailed(targetDir, error.localizedDescription)
        }

        let originalName = zipURL.lastPathComponent
        var destinationZip = targetDir.appendingPathComponent(originalName)
        if fileManager.fileExists(atPath: destinationZip.path) {
            let base = (originalName as NSString).deletingPathExtension
            let suffix = Self.timeSuffix(date: dateProvider())
            destinationZip = targetDir.appendingPathComponent("\(base)_\(suffix).zip")
        }

        let extractBase = (destinationZip.lastPathComponent as NSString).deletingPathExtension
        let extractDir = targetDir.appendingPathComponent(extractBase, isDirectory: true)
        do {
            try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
        } catch {
            throw UnpackError.createDirectoryFailed(extractDir, error.localizedDescription)
        }

        do {
            try fileManager.moveItem(at: zipURL, to: destinationZip)
        } catch {
            throw UnpackError.moveFailed(zipURL, destinationZip, error.localizedDescription)
        }

        try extract(zip: destinationZip, to: extractDir)

        do {
            try fileManager.removeItem(at: destinationZip)
        } catch {
            throw UnpackError.deleteZipFailed(destinationZip, error.localizedDescription)
        }

        // 默认不再自动打开访达；由 UI 按需调用 openFinder / UnpackService.openInFinder
        openFinder(extractDir)
        return UnpackResult(extractDirectory: extractDir, movedZip: destinationZip)
    }

    public static func dayFolderName(date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    public static func timeSuffix(date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "HHmmss"
        return f.string(from: date)
    }

    private func extract(zip: URL, to directory: URL) throws {
        let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
        if fileManager.isExecutableFile(atPath: ditto.path) {
            let result = try processRunner.run(executable: ditto, arguments: ["-x", "-k", zip.path, directory.path])
            if result.exitCode == 0 { return }
            throw UnpackError.extractFailed(result.stderr.isEmpty ? "ditto exit \(result.exitCode)" : result.stderr)
        }

        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        if fileManager.isExecutableFile(atPath: unzip.path) {
            let result = try processRunner.run(executable: unzip, arguments: ["-q", zip.path, "-d", directory.path])
            if result.exitCode == 0 { return }
            throw UnpackError.extractFailed(result.stderr.isEmpty ? "unzip exit \(result.exitCode)" : result.stderr)
        }

        throw UnpackError.extractFailed("系统缺少 ditto/unzip")
    }

    public static func openInFinder(_ folder: URL) {
        let script = """
        tell application "Finder"
            activate
            make new Finder window to POSIX file "\(folder.path)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
