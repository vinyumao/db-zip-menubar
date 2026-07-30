import Foundation

public struct PathHistoryItem: Codable, Hashable, Sendable, Equatable {
    public var path: String
    public var ts: Int

    public init(path: String, ts: Int) {
        self.path = path
        self.ts = ts
    }
}

public struct DeviceHistoryItem: Codable, Hashable, Sendable, Equatable {
    public var sn: String
    public var brand: String
    public var model: String
    public var ts: Int

    public init(sn: String, brand: String, model: String, ts: Int) {
        self.sn = sn
        self.brand = brand
        self.model = model
        self.ts = ts
    }
}

public struct LastSuccessfulAction: Codable, Hashable, Sendable, Equatable {
    public var kind: DestinationKind
    public var contentMode: ContentMode
    public var path: String?
    public var deviceSN: String?
    public var deviceBrand: String?
    public var deviceModel: String?
    public var usedDeviceFallback: Bool
    public var ts: Int

    public init(
        kind: DestinationKind,
        contentMode: ContentMode,
        path: String? = nil,
        deviceSN: String? = nil,
        deviceBrand: String? = nil,
        deviceModel: String? = nil,
        usedDeviceFallback: Bool = false,
        ts: Int
    ) {
        self.kind = kind
        self.contentMode = contentMode
        self.path = path
        self.deviceSN = deviceSN
        self.deviceBrand = deviceBrand
        self.deviceModel = deviceModel
        self.usedDeviceFallback = usedDeviceFallback
        self.ts = ts
    }

    public var modeLabel: String {
        switch contentMode {
        case .common: return "常用文件"
        case .tree: return "整目录"
        }
    }

    public var summaryLine: String {
        switch kind {
        case .path:
            let raw = path ?? "?"
            return "本地 · \(Self.abbrevPath(raw)) · \(modeLabel)"
        case .device:
            let brand = deviceBrand ?? "?"
            let model = deviceModel ?? "?"
            let sn = deviceSN ?? "?"
            let shortSN = sn.count > 8 ? String(sn.prefix(6)) + "…" : sn
            var line = "设备 · \(brand) \(model) (\(shortSN)) · \(modeLabel)"
            if usedDeviceFallback {
                line += " · 回退目录"
            }
            return line
        case .both:
            return "本地+设备 · \(modeLabel)"
        }
    }

    public static func abbrevPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

public enum LastActionAvailability: Sendable, Equatable {
    case none
    case available(LastSuccessfulAction)
    case unavailable(LastSuccessfulAction, reason: String)

    public var action: LastSuccessfulAction? {
        switch self {
        case .none: return nil
        case .available(let action), .unavailable(let action, _): return action
        }
    }

    public var isReady: Bool {
        if case .available = self { return true }
        return false
    }

    public var blockReason: String? {
        if case .unavailable(_, let reason) = self { return reason }
        return nil
    }
}

public enum LastActionValidator {
    public static func resolve(
        action: LastSuccessfulAction?,
        fileManager: FileManager = .default,
        readyDeviceSNs: () throws -> Set<String>
    ) -> LastActionAvailability {
        guard let action else { return .none }
        switch action.kind {
        case .both:
            return .none
        case .path:
            guard let path = action.path, !path.isEmpty else {
                return .unavailable(action, reason: "上次路径记录不完整，请自定义处理。")
            }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                return .unavailable(action, reason: "上次路径不存在或不是目录，请自定义处理重新选择。")
            }
            guard fileManager.isWritableFile(atPath: path) else {
                return .unavailable(action, reason: "上次路径不可写，请自定义处理重新选择。")
            }
            return .available(action)
        case .device:
            guard let sn = action.deviceSN, !sn.isEmpty else {
                return .unavailable(action, reason: "上次设备记录不完整，请自定义处理。")
            }
            do {
                let ready = try readyDeviceSNs()
                if ready.contains(sn) {
                    return .available(action)
                }
                return .unavailable(action, reason: "上次设备未连接或找不到，请连接后重试，或自定义处理。")
            } catch {
                return .unavailable(action, reason: error.localizedDescription)
            }
        }
    }
}

public struct HistoryData: Codable, Sendable, Equatable {
    public var paths: [PathHistoryItem]
    public var devices: [DeviceHistoryItem]
    public var lastSuccessfulAction: LastSuccessfulAction?

    public init(
        paths: [PathHistoryItem] = [],
        devices: [DeviceHistoryItem] = [],
        lastSuccessfulAction: LastSuccessfulAction? = nil
    ) {
        self.paths = paths
        self.devices = devices
        self.lastSuccessfulAction = lastSuccessfulAction
    }
}

public struct ListedPath: Sendable, Equatable {
    public var path: String
    public var isLast: Bool

    public init(path: String, isLast: Bool) {
        self.path = path
        self.isLast = isLast
    }
}

public struct ListedDevice: Sendable, Equatable {
    public var sn: String
    public var brand: String
    public var model: String
    public var isLast: Bool

    public init(sn: String, brand: String, model: String, isLast: Bool) {
        self.sn = sn
        self.brand = brand
        self.model = model
        self.isLast = isLast
    }

    public var displayName: String {
        let base = "\(brand) \(model) (\(sn))"
        return isLast ? "\(base)（上次）" : base
    }
}

public final class HistoryStore: @unchecked Sendable {
    public static let maxHistory = 10

    private let fileURL: URL
    private let legacyURL: URL
    private let migratedMarkerURL: URL
    private let fileManager: FileManager
    private let now: () -> Int
    private let lock = NSLock()
    private var cache: HistoryData

    public init(
        appSupportDirectory: URL,
        legacyHistoryURL: URL = HistoryStore.defaultLegacyURL,
        fileManager: FileManager = .default,
        now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }
    ) {
        self.fileManager = fileManager
        self.now = now
        self.fileURL = appSupportDirectory.appendingPathComponent("history.json")
        self.legacyURL = legacyHistoryURL
        self.migratedMarkerURL = appSupportDirectory.appendingPathComponent("history.migrated")
        try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        self.cache = HistoryStore.load(from: fileURL, fileManager: fileManager) ?? HistoryData()
        migrateIfNeeded()
    }

    public static var defaultLegacyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/db-zip-copy/history.json")
    }

    public func listPaths() -> [ListedPath] {
        lock.lock()
        defer { lock.unlock() }
        let items = Array(cache.paths.sorted { $0.ts > $1.ts }.prefix(Self.maxHistory))
        return items.enumerated().map { ListedPath(path: $0.element.path, isLast: $0.offset == 0) }
    }

    public func isPathKnown(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache.paths.contains { $0.path == path }
    }

    public func touchPath(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        let ts = now()
        var items = cache.paths.filter { $0.path != path }
        items.insert(PathHistoryItem(path: path, ts: ts), at: 0)
        cache.paths = Array(items.prefix(Self.maxHistory))
        persistLocked()
    }

    public func listDevices() -> [ListedDevice] {
        lock.lock()
        defer { lock.unlock() }
        let items = Array(cache.devices.sorted { $0.ts > $1.ts }.prefix(Self.maxHistory))
        return items.enumerated().map {
            ListedDevice(sn: $0.element.sn, brand: $0.element.brand, model: $0.element.model, isLast: $0.offset == 0)
        }
    }

    public func lastDeviceSN() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache.devices.sorted { $0.ts > $1.ts }.first?.sn
    }

    public func touchDevice(sn: String, brand: String, model: String) {
        lock.lock()
        defer { lock.unlock() }
        let ts = now()
        var items = cache.devices.filter { $0.sn != sn }
        items.insert(DeviceHistoryItem(sn: sn, brand: brand, model: model, ts: ts), at: 0)
        cache.devices = Array(items.prefix(Self.maxHistory))
        persistLocked()
    }

    public func currentData() -> HistoryData {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    public func lastSuccessfulAction() -> LastSuccessfulAction? {
        lock.lock()
        defer { lock.unlock() }
        return cache.lastSuccessfulAction
    }

    public func saveLastSuccessfulAction(_ action: LastSuccessfulAction) {
        lock.lock()
        defer { lock.unlock() }
        cache.lastSuccessfulAction = action
        persistLocked()
    }

    public func lastActionAvailability(readyDeviceSNs: () throws -> Set<String>) -> LastActionAvailability {
        LastActionValidator.resolve(
            action: lastSuccessfulAction(),
            fileManager: fileManager,
            readyDeviceSNs: readyDeviceSNs
        )
    }

    private func migrateIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: migratedMarkerURL.path) { return }
        guard let legacy = HistoryStore.load(from: legacyURL, fileManager: fileManager) else {
            try? "skipped".write(to: migratedMarkerURL, atomically: true, encoding: .utf8)
            return
        }
        if cache.paths.isEmpty && cache.devices.isEmpty {
            cache = legacy
            persistLocked()
        }
        try? "done".write(to: migratedMarkerURL, atomically: true, encoding: .utf8)
    }

    private func persistLocked() {
        do {
            let data = try JSONEncoder.pretty.encode(cache)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 持久化失败不抛到 UI 主路径；下次启动会丢最近改动。
        }
    }

    private static func load(from url: URL, fileManager: FileManager) -> HistoryData? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HistoryData.self, from: data)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
