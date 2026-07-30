import Foundation

public struct AppSettings: Codable, Sendable, Equatable {
    public var watchDirectory: String
    public var dbRootDirectory: String
    public var adbPath: String?
    public var openAtLogin: Bool
    public var stabilitySeconds: Double
    public var watchingEnabled: Bool

    public init(
        watchDirectory: String = AppSettings.defaultWatchDirectory,
        dbRootDirectory: String = AppSettings.defaultDBRootDirectory,
        adbPath: String? = nil,
        openAtLogin: Bool = true,
        stabilitySeconds: Double = 2.5,
        watchingEnabled: Bool = true
    ) {
        self.watchDirectory = watchDirectory
        self.dbRootDirectory = dbRootDirectory
        self.adbPath = adbPath
        self.openAtLogin = openAtLogin
        self.stabilitySeconds = stabilitySeconds
        self.watchingEnabled = watchingEnabled
    }

    public static var defaultWatchDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .path
    }

    public static var defaultDBRootDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/db")
            .path
    }

    public var watchDirectoryURL: URL { URL(fileURLWithPath: (watchDirectory as NSString).standardizingPath) }
    public var dbRootDirectoryURL: URL { URL(fileURLWithPath: (dbRootDirectory as NSString).standardizingPath) }
}

public final class SettingsStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cache: AppSettings

    public init(appSupportDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = appSupportDirectory.appendingPathComponent("settings.json")
        try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.cache = decoded
        } else {
            self.cache = AppSettings()
            persistLocked()
        }
    }

    public func load() -> AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        mutate(&cache)
        persistLocked()
    }

    public func save(_ settings: AppSettings) {
        lock.lock()
        defer { lock.unlock() }
        cache = settings
        persistLocked()
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder.pretty.encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
