import AppKit
import Combine
import DbZipCore
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var pendingCount: Int = 0
    @Published var pendingJobs: [PendingJob] = []
    @Published var activeCoordinator: WizardCoordinator?
    @Published var showSettingsHint: String?
    @Published var manualMismatch: ManualMismatchState?
    @Published var pendingUserMessage: String?

    @Published var presets: [ProcessingPreset] = []
    @Published var maintenanceBusy = false
    @Published var watchingStarting = false
    @Published var watcherRunning = false
    private var watchGeneration = UUID()
    @Published var batchPreset: ProcessingPreset?
    let presetStore: PresetStore

    let history: HistoryStore
    let extractHistory: ExtractHistoryStore
    let ignoreStore: IgnoreStore
    let pendingStore: PendingStore
    let settingsStore: SettingsStore
    let jobQueue: JobQueue
    let watcher: DownloadWatcher
    let appSupportURL: URL
    @Published var extractSessions: [ExtractSession] = []

    struct ManualMismatchState: Identifiable {
        let id = UUID()
        let url: URL
        let reason: String
    }

    init() {
        let support = AppPaths.applicationSupportDirectory()
        let settingsStore = SettingsStore(appSupportDirectory: support)
        let loaded = settingsStore.load()
        self.appSupportURL = support
        self.settingsStore = settingsStore
        self.settings = loaded
        self.presetStore = PresetStore(appSupportDirectory: support)
        self.presets = presetStore.presets
        self.history = HistoryStore(appSupportDirectory: support)
        self.extractHistory = ExtractHistoryStore(appSupportDirectory: support)
        self.ignoreStore = IgnoreStore(appSupportDirectory: support)
        self.pendingStore = PendingStore(appSupportDirectory: support)
        self.jobQueue = JobQueue(pendingStore: pendingStore, ignoreStore: ignoreStore)
        self.watcher = DownloadWatcher(stabilitySeconds: loaded.stabilitySeconds)
        self.jobQueue.delegate = self
        self.watcher.delegate = self
        refreshPending()
        refreshExtractSessions()
        requestNotificationPermission()
        applyLoginItem(loaded.openAtLogin)
        if loaded.watchingEnabled {
            startWatching(requestAccess: false)
        }
    }

    func refreshExtractSessions() {
        extractSessions = extractHistory.list(existingOnly: false)
    }

    func refreshPending() {
        pendingJobs = jobQueue.pendingJobs
        pendingCount = jobQueue.pendingCount
    }

    var activeJobIsIrreversible: Bool {
        guard let activeCoordinator else { return false }
        return activeCoordinator.step.isIrreversibleInProgress || activeCoordinator.preparing
    }

    func canDeletePending(id: String) -> Bool {
        guard let active = activeCoordinator, active.job.id == id else { return true }
        return !active.step.isIrreversibleInProgress && !active.preparing
    }

    func startWatching(requestAccess: Bool = true) {
        settings.watchingEnabled = true
        settingsStore.update { $0.watchingEnabled = true }
        watchGeneration = UUID()
        guard !watchingStarting else { return }
        let generation = watchGeneration
        let dir = settings.watchDirectoryURL
        watchingStarting = true
        watcherRunning = false
        watcher.stop()
        watcher.updateStabilitySeconds(settings.stabilitySeconds)
        Task {
            // TCC can wait for a user response while the Mac is locked. Never make
            // that system call on the UI thread or issue concurrent probes.
            let result = try? await runInBackground { FolderAccess.probe(dir) }
            watchingStarting = false
            guard generation == watchGeneration else {
                if settings.watchingEnabled { startWatching(requestAccess: false) }
                return
            }
            switch result {
            case .accessible:
                showSettingsHint = nil
                watcher.start(directory: dir, confirmedAccess: true)
                watcherRunning = true
            case .denied, .missing, .none:
                guard requestAccess, let chosen = FolderAccess.requestAccessViaOpenPanel(targeting: dir) else {
                    stopWatching()
                    showSettingsHint = "无法访问监听目录。请解锁 Mac，在设置中选择目录并确认系统授权。"
                    return
                }
                settings.watchDirectory = chosen.path
                settingsStore.save(settings)
                watcher.start(directory: chosen, confirmedAccess: true)
                watcherRunning = true
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(8))
            if generation == watchGeneration, watchingStarting {
                showSettingsHint = "正在等待系统返回目录访问结果；若 Mac 已锁屏，请解锁后确认目录授权。"
            }
        }
    }

    func stopWatching() {
        watchGeneration = UUID()
        watcherRunning = false
        watcher.stop()
        settingsStore.update { $0.watchingEnabled = false }
        settings.watchingEnabled = false
    }

    func saveSettings(_ newSettings: AppSettings) {
        guard newSettings.stabilitySeconds.isFinite, (0.5...60).contains(newSettings.stabilitySeconds),
              newSettings.watchDirectoryURL.path.hasPrefix("/"), !newSettings.watchDirectory.trimmingCharacters(in: .whitespaces).isEmpty,
              !newSettings.dbRootDirectory.trimmingCharacters(in: .whitespaces).isEmpty else {
            showSettingsHint = "目录不能为空，稳定等待时间应为 0.5–60 秒。"
            return
        }
        showSettingsHint = nil
        settings = newSettings
        settingsStore.save(newSettings)
        applyLoginItem(newSettings.openAtLogin)
        watcher.updateStabilitySeconds(newSettings.stabilitySeconds)
        if newSettings.watchingEnabled {
            startWatching()
        } else {
            stopWatching()
        }
    }

    func applyLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showSettingsHint = "登录项更新失败: \(error.localizedDescription)"
        }
    }

    /// 打开 wizard；缺文件则提示并删记录。返回是否成功打开。
    @discardableResult
    func openWizard(for job: PendingJob) -> Bool {
        guard !maintenanceBusy else { return false }
        if let active = activeCoordinator {
            if active.job.id == job.id {
                NotificationCenter.default.post(name: .openWizardWindow, object: nil)
                return true
            }
            if active.preparing { return false }
        }
        guard FileManager.default.fileExists(atPath: job.identity.path) else {
            jobQueue.removeRecord(id: job.id)
            refreshPending()
            if activeCoordinator?.job.id == job.id {
                dismissWizard()
            }
            presentAlert(title: "文件不存在", message: "「\(job.fileName)」已不在原路径，已从待处理中移除该记录。")
            return false
        }

        if let active = activeCoordinator, active.job.id != job.id {
            switch active.step {
            case .confirm, .success, .partialSuccess, .failure:
                break
            default:
                presentAlert(title: "已有进行中的任务", message: "请先完成、稍后或取消当前 wizard，再打开其他项。")
                return false
            }
        }

        jobQueue.begin(job)
        activeCoordinator = WizardCoordinator(
            job: job,
            settings: settings,
            history: history,
            extractHistory: extractHistory,
            makeAdb: { [weak self] in
                AdbClient(configuredPath: self?.settings.adbPath)
            }
        )
        NotificationCenter.default.post(name: .openWizardWindow, object: nil)
        return true
    }

    func openExtractSession(_ session: ExtractSession) -> Bool {
        guard !maintenanceBusy, activeCoordinator?.preparing != true else { return false }
        guard extractHistory.validateAndKeep(session) else {
            refreshExtractSessions()
            presentAlert(title: "目录不存在", message: "该解压目录已不在，已从历史中移除。")
            return false
        }

        if let active = activeCoordinator {
            switch active.step {
            case .confirm, .success, .partialSuccess, .failure:
                break
            default:
                presentAlert(title: "已有进行中的任务", message: "请先完成、稍后或取消当前 wizard，再继续历史项。")
                return false
            }
        }

        activeCoordinator = WizardCoordinator.resumeFromExtract(
            extractDirectory: session.extractURL,
            sourceFileName: session.sourceFileName,
            settings: settings,
            history: history,
            extractHistory: extractHistory,
            makeAdb: { [weak self] in
                AdbClient(configuredPath: self?.settings.adbPath)
            }
        )
        NotificationCenter.default.post(name: .openWizardWindow, object: nil)
        return true
    }

    func deleteExtractSession(id: String) {
        extractHistory.remove(id: id)
        refreshExtractSessions()
    }

    func openPending(id: String) {
        guard let job = pendingJobs.first(where: { $0.id == id }) ?? pendingStore.all().first(where: { $0.id == id }) else {
            return
        }
        _ = openWizard(for: job)
    }

    func deletePendingRecord(id: String) {
        guard canDeletePending(id: id) else {
            presentAlert(title: "无法删除", message: "该任务正在解压或复制中，请等待完成或结束后再删记录。")
            return
        }
        if activeCoordinator?.job.id == id {
            dismissWizard()
            jobQueue.cancelActiveWithoutRemovingPending()
        }
        jobQueue.removeRecord(id: id)
        refreshPending()
        closePendingListIfEmpty()
    }

    /// - Returns: 被跳过（进行中不可删）的数量
    @discardableResult
    func clearPendingRecords() -> Int {
        var protected = Set<String>()
        if let active = activeCoordinator, active.step.isIrreversibleInProgress || active.preparing {
            protected.insert(active.job.id)
        }
        let skipped = protected.count
        if let active = activeCoordinator, !protected.contains(active.job.id) {
            dismissWizard()
            jobQueue.cancelActiveWithoutRemovingPending()
        }
        jobQueue.clearRecords(exceptIDs: protected)
        refreshPending()
        closePendingListIfEmpty()
        return skipped
    }

    func chooseZipManually() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.zip]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "选择 zip"
        guard panel.runModal() == .OK else { return }
        if panel.urls.count > 1 { enqueueFiles(panel.urls); return }
        guard let url = panel.url else { return }

        if let reason = ZipMatcher.mismatchReason(for: url.lastPathComponent) {
            manualMismatch = ManualMismatchState(url: url, reason: reason)
            return
        }
        enqueueAndOpen(url: url, force: false)
    }

    func enqueueFiles(_ urls: [URL]) {
        var rejected: [String] = []
        for url in urls {
            guard url.isFileURL, ZipMatcher.isTargetZip(url.lastPathComponent) else {
                rejected.append(url.lastPathComponent); continue
            }
            do { _ = try jobQueue.ingestManual(url: url, force: false) }
            catch { rejected.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        refreshPending()
        NotificationCenter.default.post(name: .openPendingListWindow, object: nil)
        if !rejected.isEmpty {
            pendingUserMessage = "以下文件未入队；不匹配的 ZIP 可单独选择并强制处理：\n" + rejected.joined(separator: "\n")
        }
    }

    func savePreset(name: String, coordinator: WizardCoordinator) throws {
        try presetStore.save(coordinator.makePreset(name: name))
        presets = presetStore.presets
    }

    func deletePreset(_ preset: ProcessingPreset) {
        do { try presetStore.remove(id: preset.id); presets = presetStore.presets }
        catch { pendingUserMessage = error.localizedDescription }
    }

    func finishAndOpenNext() {
        guard let current = activeCoordinator else { return }
        jobQueue.markFinished(current.job)
        activeCoordinator = nil
        refreshPending()
        refreshExtractSessions()
        if let next = pendingJobs.first, openWizard(for: next) {
            if let preset = batchPreset, let coordinator = activeCoordinator {
                Task { await coordinator.startPreset(preset) }
            }
        } else { batchPreset = nil; dismissWizard(); closePendingListIfEmpty() }
    }

    func startBatch(preset: ProcessingPreset) {
        guard activeCoordinator == nil, let next = pendingJobs.first else {
            pendingUserMessage = "请先结束当前流程，再启动批量处理。"
            return
        }
        batchPreset = preset
        if openWizard(for: next), let coordinator = activeCoordinator {
            Task { await coordinator.startPreset(preset) }
        }
    }

    func forceProcessMismatchedZip() {
        guard let state = manualMismatch else { return }
        manualMismatch = nil
        enqueueAndOpen(url: state.url, force: true)
    }

    private func enqueueAndOpen(url: URL, force: Bool) {
        do {
            let job = try jobQueue.ingestManual(url: url, force: force)
            refreshPending()
            _ = openWizard(for: job)
        } catch {
            presentAlert(title: "无法打开文件", message: error.localizedDescription)
        }
    }

    func handleIgnore() {
        guard let coordinator = activeCoordinator else { return }
        jobQueue.markIgnored(coordinator.job)
        dismissWizard()
        refreshPending()
        closePendingListIfEmpty()
    }

    func handleLater() {
        guard let coordinator = activeCoordinator else { return }
        jobQueue.markLater(coordinator.job)
        dismissWizard()
        refreshPending()
    }

    func handleCancelCopyKeepExtract() {
        handleWizardFinished()
        refreshExtractSessions()
        pendingUserMessage = "已保留解压目录。可从菜单「解压历史」继续复制或推送。"
    }

    func handleWizardFinished() {
        guard let coordinator = activeCoordinator else { return }
        batchPreset = nil
        jobQueue.markFinished(coordinator.job)
        dismissWizard()
        refreshPending()
        refreshExtractSessions()
        closePendingListIfEmpty()
    }

    /// 清掉进行中任务并关闭 Wizard 窗口，避免停在「没有进行中的任务」。
    func dismissWizard() {
        activeCoordinator = nil
        NotificationCenter.default.post(name: .dismissWizardWindow, object: nil)
        // 通知可能尚未送达时再兜底关一次
        DispatchQueue.main.async {
            WindowFront.closeWizardWindow()
        }
    }

    /// 流程结束后若已无待处理项，自动关掉待处理窗口，避免多一步手动关闭。
    func closePendingListIfEmpty() {
        guard pendingJobs.isEmpty else { return }
        WindowFront.closePendingWindow()
    }

    func requestQuit() {
        guard !maintenanceBusy else { pendingUserMessage = "正在清理目录，完成后即可退出。"; return }
        if activeJobIsIrreversible {
            activeCoordinator?.cancelOperation()
            Task {
                while activeJobIsIrreversible { try? await Task.sleep(for: .milliseconds(200)) }
                NSApplication.shared.terminate(nil)
            }
        } else { NSApplication.shared.terminate(nil) }
    }

    func openAppSupport() {
        NSWorkspace.shared.activateFileViewerSelecting([appSupportURL])
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        NotificationDelegate.shared.onOpenJob = { [weak self] id in
            Task { @MainActor in
                self?.openPending(id: id)
            }
        }
    }

    func notifyNewJob(_ job: PendingJob) {
        let content = UNMutableNotificationContent()
        content.title = "发现待处理 DB zip"
        content.body = job.fileName
        content.sound = .default
        content.userInfo = ["jobId": job.id]
        let request = UNNotificationRequest(identifier: job.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    fileprivate func presentAlert(title: String, message: String) {
        WindowFront.activateApp()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

extension AppModel: JobQueueDelegate {
    func jobQueueDidUpdatePendingCount(_ count: Int) {
        pendingCount = count
        pendingJobs = jobQueue.pendingJobs
    }
}

extension AppModel: DownloadWatcherDelegate {
    nonisolated func downloadWatcher(didDetectStableZip url: URL) {
        Task { @MainActor in
            do {
                if let job = try jobQueue.ingestDetected(url: url, force: false) {
                    refreshPending()
                    notifyNewJob(job)
                }
            } catch {
                presentAlert(title: "入队失败", message: error.localizedDescription)
            }
        }
    }

    nonisolated func downloadWatcher(accessDenied directory: URL) {
        Task { @MainActor in
            stopWatching()
            showSettingsHint = "无法访问 \(directory.path)，已暂停监听。请从菜单重新「开始监听」并在面板中授权。"
        }
    }
}

extension Notification.Name {
    static let openWizardWindow = Notification.Name("tools.wayne.db-zip-menubar.openWizard")
    static let dismissWizardWindow = Notification.Name("tools.wayne.db-zip-menubar.dismissWizard")
    static let openPendingListWindow = Notification.Name("tools.wayne.db-zip-menubar.openPendingList")
    static let openExtractHistoryWindow = Notification.Name("tools.wayne.db-zip-menubar.openExtractHistory")
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    var onOpenJob: ((String) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = response.notification.request.content.userInfo["jobId"] as? String {
            onOpenJob?(id)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
