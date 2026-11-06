import Foundation

public protocol DownloadWatcherDelegate: AnyObject {
    func downloadWatcher(didDetectStableZip url: URL)
    func downloadWatcher(accessDenied directory: URL)
}

public extension DownloadWatcherDelegate {
    func downloadWatcher(accessDenied directory: URL) {}
}

/// 目录监听：临时名过滤 + size 稳定后产出候选。冷启动不扫描遗留文件。
public final class DownloadWatcher: NSObject, @unchecked Sendable {
    public weak var delegate: DownloadWatcherDelegate?

    private let fileManager: FileManager
    private var stabilitySeconds: Double
    private var watchDirectory: URL?
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private let queue = DispatchQueue(label: "tools.wayne.db-zip-menubar.watcher")
    private var knownFiles: [String: FileIdentity] = [:]
    private var pendingSizes: [String: (identity: FileIdentity, since: Date)] = [:]
    private var generation = UUID()
    private var started = false
    private var timer: DispatchSourceTimer?
    private var hasAccess = false
    private var accessDeniedNotified = false
    private var scanning = false

    public init(fileManager: FileManager = .default, stabilitySeconds: Double = 2.5) {
        self.fileManager = fileManager
        self.stabilitySeconds = max(0.1, stabilitySeconds)
        super.init()
    }

    public func updateStabilitySeconds(_ seconds: Double) {
        queue.async { self.stabilitySeconds = max(0.1, seconds) }
    }

    /// - Parameter confirmedAccess: 调用方已在主线程完成单次授权探测时传 true。
    public func start(directory: URL, confirmedAccess: Bool = false) {
        queue.async {
            self.stopLocked()
            self.watchDirectory = directory
            self.accessDeniedNotified = false
            self.hasAccess = confirmedAccess

            if !self.hasAccess {
                switch FolderAccess.probe(directory, fileManager: self.fileManager) {
                case .accessible:
                    self.hasAccess = true
                case .denied:
                    self.notifyAccessDenied(directory)
                    return
                case .missing:
                    self.notifyAccessDenied(directory)
                    return
                }
            }

            self.seedKnownFiles(in: directory)
            guard self.hasAccess else { return }
            self.startSourceLocked(directory: directory)
            self.startPollingTimerLocked()
            self.started = true
        }
    }

    public func stop() {
        queue.async { self.stopLocked() }
    }

    public func isWatching() -> Bool {
        queue.sync { started }
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        source?.cancel()
        source = nil
        directoryFD = -1
        generation = UUID()
        pendingSizes.removeAll()
        started = false
        scanning = false
    }

    private func notifyAccessDenied(_ directory: URL) {
        guard !accessDeniedNotified else { return }
        accessDeniedNotified = true
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.downloadWatcher(accessDenied: directory)
        }
    }

    private func seedKnownFiles(in directory: URL) {
        knownFiles.removeAll()
        do {
            let items = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for item in items {
                if DownloadTempFilter.isCandidateZipName(item.lastPathComponent), let identity = try? FileIdentity(url: item) {
                    knownFiles[identity.path] = identity
                }
            }
            hasAccess = true
        } catch {
            hasAccess = false
            notifyAccessDenied(directory)
        }
    }

    private func startSourceLocked(directory: URL) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib, .link],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.scanLocked()
        }
        // Close this source's descriptor only after cancellation; a new source may
        // already exist by the time this callback runs.
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func startPollingTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 仅作 FSEvents 补充；有权限后低频轮询，避免狂扫触发 TCC
        timer.schedule(deadline: .now() + 1.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.scanLocked()
            self?.checkStabilityLocked()
        }
        self.timer = timer
        timer.resume()
    }

    private func scanLocked() {
        guard hasAccess, let directory = watchDirectory, !scanning else { return }
        scanning = true
        defer { scanning = false }

        let items: [URL]
        do {
            items = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: []
            )
        } catch {
            hasAccess = false
            stopLocked()
            notifyAccessDenied(directory)
            return
        }

        var current: [String: FileIdentity] = [:]
        for item in items where DownloadTempFilter.isCandidateZipName(item.lastPathComponent) {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
                  let identity = try? FileIdentity(url: item) else { continue }
            current[identity.path] = identity
            if knownFiles[identity.path] != identity {
                pendingSizes[identity.path] = (identity, Date())
            }
        }
        knownFiles = current
        for path in Array(pendingSizes.keys) where current[path] == nil {
            pendingSizes.removeValue(forKey: path)
        }
    }

    private func checkStabilityLocked() {
        guard hasAccess else { return }
        let now = Date()
        var ready: [URL] = []
        for (path, info) in pendingSizes {
            if info.identity.fileSize > 0, now.timeIntervalSince(info.since) >= stabilitySeconds {
                ready.append(URL(fileURLWithPath: path))
            }
        }
        for url in ready {
            let path = FileIdentity.normalizePath(url.path)
            pendingSizes.removeValue(forKey: path)
            guard fileManager.fileExists(atPath: path) else { continue }
            let name = url.lastPathComponent
            guard DownloadTempFilter.isCandidateZipName(name) else { continue }
            let generation = self.generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.queue.sync(execute: { self.started && self.generation == generation }) else { return }
                self.delegate?.downloadWatcher(didDetectStableZip: url)
            }
        }
    }
}
