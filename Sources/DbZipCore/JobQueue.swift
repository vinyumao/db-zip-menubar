import Foundation

@MainActor
public protocol JobQueueDelegate: AnyObject {
    func jobQueueDidUpdatePendingCount(_ count: Int)
}

/// 串行队列：稍后项不自动弹出；用户从菜单/通知打开。
@MainActor
public final class JobQueue {
    public weak var delegate: JobQueueDelegate?

    private let pendingStore: PendingStore
    private let ignoreStore: IgnoreStore
    private var activeJobID: String?

    public init(pendingStore: PendingStore, ignoreStore: IgnoreStore) {
        self.pendingStore = pendingStore
        self.ignoreStore = ignoreStore
    }

    public var pendingCount: Int { pendingStore.count() }
    public var pendingJobs: [PendingJob] { pendingStore.all() }
    public var isBusy: Bool { activeJobID != nil }
    public var activeJobIDValue: String? { activeJobID }

    /// 监听命中入队；不自动弹窗。已在队列则返回 nil。
    @discardableResult
    public func ingestDetected(url: URL, force: Bool = false) throws -> PendingJob? {
        let identity = try FileIdentity(url: url)
        if ignoreStore.isIgnored(identity) { return nil }
        if let existing = pendingStore.all().first(where: { $0.identity.path == identity.path }) {
            if existing.identity == identity || existing.id == activeJobID { return nil }
            pendingStore.remove(id: existing.id)
        }
        if !force && !ZipMatcher.isTargetZip(url.lastPathComponent) {
            return nil
        }
        let job = PendingJob(
            identity: identity,
            fileName: url.lastPathComponent,
            forced: force
        )
        pendingStore.upsert(job)
        notifyCount()
        return job
    }

    /// 手动选择：已存在则返回已有项。
    public func ingestManual(url: URL, force: Bool) throws -> PendingJob {
        let identity = try FileIdentity(url: url)
        if let existing = pendingStore.all().first(where: { $0.identity.path == identity.path }) {
            if existing.identity != identity, existing.id != activeJobID {
                let updated = PendingJob(identity: identity, fileName: url.lastPathComponent, forced: force)
                pendingStore.upsert(updated)
                notifyCount()
                return updated
            }
            if force && !existing.forced {
                let updated = PendingJob(
                    id: existing.id,
                    identity: existing.identity,
                    fileName: existing.fileName,
                    createdAt: existing.createdAt,
                    forced: true
                )
                pendingStore.upsert(updated)
                notifyCount()
                return updated
            }
            return existing
        }
        let job = PendingJob(
            identity: identity,
            fileName: url.lastPathComponent,
            forced: force
        )
        pendingStore.upsert(job)
        notifyCount()
        return job
    }

    public func begin(_ job: PendingJob) {
        activeJobID = job.id
    }

    public func markLater(_ job: PendingJob) {
        pendingStore.upsert(job)
        activeJobID = nil
        notifyCount()
    }

    public func markIgnored(_ job: PendingJob) {
        ignoreStore.ignore(job.identity)
        pendingStore.remove(id: job.id)
        activeJobID = nil
        notifyCount()
    }

    public func markFinished(_ job: PendingJob) {
        pendingStore.remove(id: job.id)
        if activeJobID == job.id {
            activeJobID = nil
        }
        notifyCount()
    }

    public func removeRecord(id: String) {
        pendingStore.remove(id: id)
        if activeJobID == id {
            activeJobID = nil
        }
        notifyCount()
    }

    public func clearRecords(exceptIDs: Set<String> = []) {
        for job in pendingStore.all() where !exceptIDs.contains(job.id) {
            pendingStore.remove(id: job.id)
        }
        if let activeJobID, !exceptIDs.contains(activeJobID) {
            self.activeJobID = nil
        }
        notifyCount()
    }

    public func cancelActiveWithoutRemovingPending() {
        activeJobID = nil
    }

    private func notifyCount() {
        delegate?.jobQueueDidUpdatePendingCount(pendingStore.count())
    }
}
