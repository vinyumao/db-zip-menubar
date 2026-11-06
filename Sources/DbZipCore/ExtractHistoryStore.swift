import Foundation

public struct ExtractSession: Codable, Hashable, Sendable, Equatable, Identifiable {
    public var id: String
    public var extractPath: String
    public var sourceFileName: String
    public var createdAt: TimeInterval
    public var status: String?
    public var destination: String?
    public var lastError: String?
    public var duration: TimeInterval?

    public init(
        id: String = UUID().uuidString,
        extractPath: String,
        sourceFileName: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.extractPath = (extractPath as NSString).standardizingPath
        self.sourceFileName = sourceFileName
        self.createdAt = createdAt
    }

    public var extractURL: URL {
        URL(fileURLWithPath: extractPath)
    }
}

/// 解压完成后的会话历史：取消复制后仍可从这里继续推送/拷贝。
public final class ExtractHistoryStore: @unchecked Sendable {
    public static let maxSessions = 100

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var sessions: [ExtractSession]

    public init(appSupportDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = appSupportDirectory.appendingPathComponent("extract-history.json")
        try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ExtractSession].self, from: data) {
            self.sessions = decoded
        } else {
            self.sessions = []
        }
        // Do not probe protected extraction folders during app initialization.
        // Directory validation is deferred until the history is explicitly opened.
        sessions = Array(sessions.sorted { $0.createdAt > $1.createdAt }.prefix(Self.maxSessions))
        persistLocked()
    }

    public func record(extractPath: String, sourceFileName: String) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = (extractPath as NSString).standardizingPath
        guard Self.directoryExists(normalized, fileManager: fileManager) else { return }
        sessions.removeAll { $0.extractPath == normalized }
        sessions.insert(
            ExtractSession(extractPath: normalized, sourceFileName: sourceFileName),
            at: 0
        )
        pruneAndTrimLocked()
        persistLocked()
    }

    /// 按时间倒序；先校验目录仍存在，再截断为最多 100 条。
    public func list(existingOnly: Bool = true) -> [ExtractSession] {
        lock.lock()
        defer { lock.unlock() }
        if existingOnly {
            pruneAndTrimLocked()
            persistLocked()
        } else {
            sessions = Array(sessions.sorted { $0.createdAt > $1.createdAt }.prefix(Self.maxSessions))
        }
        return sessions
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeAll { $0.id == id }
        persistLocked()
    }

    public func recordOutcome(extractPath: String, status: String, destination: String?, error: String?, duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.extractPath == extractPath }) else { return }
        sessions[index].status = status
        sessions[index].destination = destination
        sessions[index].lastError = error
        sessions[index].duration = duration
        persistLocked()
    }

    /// 打开前再验一次；不存在则移除并返回 false。
    public func validateAndKeep(_ session: ExtractSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Self.directoryExists(session.extractPath, fileManager: fileManager) else {
            sessions.removeAll { $0.id == session.id || $0.extractPath == session.extractPath }
            persistLocked()
            return false
        }
        return true
    }

    public func clearMissing() {
        _ = list(existingOnly: true)
    }

    public static func directoryExists(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func pruneAndTrimLocked() {
        let sorted = sessions.sorted { $0.createdAt > $1.createdAt }
        let existing = sorted.filter { Self.directoryExists($0.extractPath, fileManager: fileManager) }
        sessions = Array(existing.prefix(Self.maxSessions))
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder.pretty.encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
