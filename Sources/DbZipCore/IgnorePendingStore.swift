import Foundation

public final class IgnoreStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var identities: [FileIdentity]

    public init(appSupportDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = appSupportDirectory.appendingPathComponent("ignored.json")
        try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([FileIdentity].self, from: data) {
            self.identities = decoded
        } else {
            self.identities = []
        }
    }

    public func isIgnored(_ identity: FileIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return identities.contains(identity)
    }

    public func ignore(_ identity: FileIdentity) {
        lock.lock()
        defer { lock.unlock() }
        identities.removeAll { $0.path == identity.path }
        identities.append(identity)
        persistLocked()
    }

    public func remove(path: String) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = FileIdentity.normalizePath(path)
        identities.removeAll { $0.path == normalized }
        persistLocked()
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder.pretty.encode(identities) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

public struct PendingJob: Codable, Hashable, Sendable, Equatable, Identifiable {
    public var id: String
    public var identity: FileIdentity
    public var fileName: String
    public var createdAt: TimeInterval
    public var forced: Bool

    public init(
        id: String = UUID().uuidString,
        identity: FileIdentity,
        fileName: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        forced: Bool = false
    ) {
        self.id = id
        self.identity = identity
        self.fileName = fileName
        self.createdAt = createdAt
        self.forced = forced
    }

    public var fileURL: URL {
        URL(fileURLWithPath: identity.path)
    }
}

public final class PendingStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var jobs: [PendingJob]

    public init(appSupportDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = appSupportDirectory.appendingPathComponent("pending.json")
        try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([PendingJob].self, from: data) {
            self.jobs = decoded
        } else {
            self.jobs = []
        }
    }

    public func all() -> [PendingJob] {
        lock.lock()
        defer { lock.unlock() }
        return jobs.sorted {
            if $0.identity.mtime != $1.identity.mtime {
                return $0.identity.mtime > $1.identity.mtime
            }
            return $0.createdAt > $1.createdAt
        }
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs.count
    }

    public func upsert(_ job: PendingJob) {
        lock.lock()
        defer { lock.unlock() }
        jobs.removeAll { $0.identity.path == job.identity.path || $0.id == job.id }
        jobs.append(job)
        persistLocked()
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        jobs.removeAll { $0.id == id }
        persistLocked()
    }

    public func remove(path: String) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = FileIdentity.normalizePath(path)
        jobs.removeAll { $0.identity.path == normalized }
        persistLocked()
    }

    public func contains(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let normalized = FileIdentity.normalizePath(path)
        return jobs.contains { $0.identity.path == normalized }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder.pretty.encode(jobs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
