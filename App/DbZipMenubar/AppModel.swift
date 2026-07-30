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
            startWatching()
        }
    }

    func refreshExtractSessions() {
        extractSessions = extractHistory.list(existingOnly: true)
    }

    func refreshPending() {
        pendingJobs = jobQueue.pendingJobs
        pendingCount = jobQueue.pendingCount
    }

    var activeJobIsIrreversible: Bool {
        guard let activeCoordinator else { return false }
        return activeCoordinator.step.isIrreversibleInProgress
    }

    func canDeletePending(id: String) -> Bool {
        guard let active = activeCoordinator, active.job.id == id else { return true }
        return !active.step.isIrreversibleInProgress
    }

    func startWatching() {
        let dir = settings.watchDirectoryURL
        watcher.stop()
        watcher.updateStabilitySeconds(settings.stabilitySeconds)

        switch FolderAccess.probe(dir) {
        case .accessible:
            watcher.start(directory: dir, confirmedAccess: true)
            settingsStore.update { $0.watchingEnabled = true }
            settings.watchingEnabled = true
        case .denied, .missing:
            guard let chosen = FolderAccess.requestAccessViaOpenPanel(targeting: dir) else {
                settingsStore.update { $0.watchingEnabled = false }
                settings.watchingEnabled = false
                showSettingsHint = "未授权访问监听目录，已暂停监听。可在菜单中重新「开始监听」。"
                return
            }
            settings.watchDirectory = chosen.path
            settingsStore.save(settings)
            settings = settingsStore.load()
            watcher.start(directory: chosen, confirmedAccess: true)
            settingsStore.update { $0.watchingEnabled = true }
            settings.watchingEnabled = true
        }
    }

    func stopWatching() {
        watcher.stop()
        settingsStore.update { $0.watchingEnabled = false }
        settings.watchingEnabled = false
    }

    func saveSettings(_ newSettings: AppSettings) {
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
        guard FileManager.default.fileExists(atPath: job.identity.path) else {
            jobQueue.removeRecord(id: job.id)
            refreshPending()
            if activeCoordinator?.job.id == job.id {
                activeCoordinator = nil
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
            activeCoordinator = nil
            jobQueue.cancelActiveWithoutRemovingPending()
        }
        jobQueue.removeRecord(id: id)
        refreshPending()
    }

    /// - Returns: 被跳过（进行中不可删）的数量
    @discardableResult
    func clearPendingRecords() -> Int {
        var protected = Set<String>()
        if let active = activeCoordinator, active.step.isIrreversibleInProgress {
            protected.insert(active.job.id)
        }
        let skipped = protected.count
        if let active = activeCoordinator, !protected.contains(active.job.id) {
            activeCoordinator = nil
            jobQueue.cancelActiveWithoutRemovingPending()
        }
        jobQueue.clearRecords(exceptIDs: protected)
        refreshPending()
        return skipped
    }

    func chooseZipManually() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择 zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let reason = ZipMatcher.mismatchReason(for: url.lastPathComponent) {
            manualMismatch = ManualMismatchState(url: url, reason: reason)
            return
        }
        enqueueAndOpen(url: url, force: false)
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
        activeCoordinator = nil
        refreshPending()
    }

    func handleLater() {
        guard let coordinator = activeCoordinator else { return }
        jobQueue.markLater(coordinator.job)
        activeCoordinator = nil
        refreshPending()
    }

    func handleCancelCopyKeepExtract() {
        handleWizardFinished()
        refreshExtractSessions()
        pendingUserMessage = "已保留解压目录。可从菜单「解压历史」继续复制或推送。"
    }

    func handleWizardFinished() {
        guard let coordinator = activeCoordinator else { return }
        jobQueue.markFinished(coordinator.job)
        activeCoordinator = nil
        refreshPending()
        refreshExtractSessions()
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
