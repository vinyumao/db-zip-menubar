import AppKit
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
    public var warning: String?

    public init(extractDirectory: URL, movedZip: URL, warning: String? = nil) {
        self.extractDirectory = extractDirectory
        self.movedZip = movedZip
        self.warning = warning
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

        // Keep the source in place until extraction is fully committed, so retries and
        // restarts can always use the original pending-job path.
        let identity = try FileIdentity(url: zipURL)
        let base = zipURL.deletingPathExtension().lastPathComponent
        var extractDir = targetDir.appendingPathComponent(base, isDirectory: true)
        var index = 1
        while fileManager.fileExists(atPath: extractDir.path) {
            extractDir = targetDir.appendingPathComponent("\(base)_\(index)", isDirectory: true)
            index += 1
        }
        let staging = targetDir.appendingPathComponent(".dbzip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        let validation = try processRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-tq", zipURL.path])
        guard validation.exitCode == 0 else {
            throw UnpackError.extractFailed("ZIP 校验失败：" + validation.stdout + validation.stderr)
        }
        try extract(zip: zipURL, to: staging)
        guard try FileIdentity(url: zipURL) == identity else {
            throw UnpackError.extractFailed("源文件仍在变化，请等待下载完成后重试")
        }
        // Never merge into an existing extraction directory.
        try fileManager.moveItem(at: staging, to: extractDir)
        var warning: String?
        do { try fileManager.removeItem(at: zipURL) }
        catch { warning = "解压成功，但原 ZIP 未能删除：\(error.localizedDescription)" }
        openFinder(extractDir)
        return UnpackResult(extractDirectory: extractDir, movedZip: zipURL, warning: warning)
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
        DispatchQueue.main.async { NSWorkspace.shared.open(folder) }
    }
}
