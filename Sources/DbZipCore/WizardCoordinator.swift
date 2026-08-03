import Combine
import Foundation

public enum WizardStep: String, Sendable, Equatable {
    case confirm
    case unpacking
    case chooseDestination
    case contentMode
    case choosePath
    case chooseDevice
    case copying
    case success
    case partialSuccess
    case failure

    /// 解压/复制进行中视为不可逆，列表管理不得删该条。
    public var isIrreversibleInProgress: Bool {
        switch self {
        case .unpacking, .copying:
            return true
        default:
            return false
        }
    }
}

public enum DestinationKind: String, Sendable, Equatable, Codable {
    case path
    case device
    /// 先本地再设备；成功不写入 lastSuccessfulAction。
    case both
}

public struct WizardSuccessSummary: Sendable, Equatable {
    public var extractDirectory: URL
    public var destinationDescription: String
    public var usedDeviceFallback: Bool
    public var pathDescription: String?
    public var deviceDescription: String?

    public init(
        extractDirectory: URL,
        destinationDescription: String,
        usedDeviceFallback: Bool = false,
        pathDescription: String? = nil,
        deviceDescription: String? = nil
    ) {
        self.extractDirectory = extractDirectory
        self.destinationDescription = destinationDescription
        self.usedDeviceFallback = usedDeviceFallback
        self.pathDescription = pathDescription
        self.deviceDescription = deviceDescription
    }
}

public struct WizardPartialSuccessSummary: Sendable, Equatable {
    public var extractDirectory: URL
    public var pathDescription: String
    public var deviceError: String

    public init(extractDirectory: URL, pathDescription: String, deviceError: String) {
        self.extractDirectory = extractDirectory
        self.pathDescription = pathDescription
        self.deviceError = deviceError
    }
}

@MainActor
public final class WizardCoordinator: ObservableObject {
    @Published public var step: WizardStep = .confirm
    @Published public var job: PendingJob
    @Published public var logLines: [String] = []
    @Published public var extractDirectory: URL?
    @Published public var contentMode: ContentMode?
    @Published public var destinationKind: DestinationKind?
    @Published public var selectedPath: String?
    @Published public var selectedDevice: AdbDevice?
    @Published public var pathIsTyped: Bool = false
    @Published public var errorMessage: String?
    @Published public var success: WizardSuccessSummary?
    @Published public var partialSuccess: WizardPartialSuccessSummary?
    @Published public var mismatchReason: String?
    @Published public var rememberPathAnswer: Bool?
    @Published public var needsRememberPrompt: Bool = false
    @Published public var lastActionAvailability: LastActionAvailability = .none
    /// 点「按上次」时若即时校验失败，展示在确认页（不开始解压）。
    @Published public var lastActionBlockReason: String?
    /// 「两个都执行」中本地段已完成。
    @Published public var pathCopyCompletedInBoth = false

    public let settings: AppSettings
    private let unpackService: UnpackService
    private let localCopy: LocalCopyService
    private let history: HistoryStore
    private let extractHistory: ExtractHistoryStore
    private let makeAdb: () -> AdbClient
    private var autoCopyAfterUnpack = false
    private var bothPathDescription: String?

    public init(
        job: PendingJob,
        settings: AppSettings,
        unpackService: UnpackService = UnpackService(),
        localCopy: LocalCopyService = LocalCopyService(),
        history: HistoryStore,
        extractHistory: ExtractHistoryStore,
        makeAdb: @escaping () -> AdbClient
    ) {
        self.job = job
        self.settings = settings
        self.unpackService = unpackService
        self.localCopy = localCopy
        self.history = history
        self.extractHistory = extractHistory
        self.makeAdb = makeAdb
        if !job.forced, let reason = ZipMatcher.mismatchReason(for: job.fileName) {
            self.mismatchReason = reason
        } else if job.forced, ZipMatcher.mismatchReason(for: job.fileName) != nil {
            self.mismatchReason = ZipMatcher.mismatchReason(for: job.fileName)
        }
        refreshLastActionAvailability()
    }

    /// 从已解压目录继续：跳过确认与解压，直接选复制目标。
    public static func resumeFromExtract(
        extractDirectory: URL,
        sourceFileName: String,
        settings: AppSettings,
        history: HistoryStore,
        extractHistory: ExtractHistoryStore,
        makeAdb: @escaping () -> AdbClient
    ) -> WizardCoordinator {
        let identity: FileIdentity
        if let live = try? FileIdentity(url: extractDirectory) {
            identity = live
        } else {
            identity = FileIdentity(
                path: extractDirectory.path,
                fileSize: 0,
                mtime: Date().timeIntervalSince1970
            )
        }
        let job = PendingJob(
            identity: identity,
            fileName: sourceFileName,
            forced: true
        )
        let coordinator = WizardCoordinator(
            job: job,
            settings: settings,
            history: history,
            extractHistory: extractHistory,
            makeAdb: makeAdb
        )
        coordinator.extractDirectory = extractDirectory
        coordinator.step = .chooseDestination
        coordinator.appendLog("从解压历史继续: \(extractDirectory.path)")
        return coordinator
    }

    public func refreshLastActionAvailability() {
        lastActionAvailability = history.lastActionAvailability { [makeAdb] in
            let result = try makeAdb().listReadyDevices()
            return Set(result.devices.map(\.sn))
        }
        if case .available = lastActionAvailability {
            lastActionBlockReason = nil
        } else if case .unavailable(_, let reason) = lastActionAvailability {
            lastActionBlockReason = reason
        } else {
            lastActionBlockReason = nil
        }
    }

    public func appendLog(_ line: String) {
        logLines.append(line)
    }

    /// 自定义向导：解压后进入选目标。
    public func startUnpack() async {
        autoCopyAfterUnpack = false
        await runUnpack()
    }

    /// 按上次成功配方：校验通过后解压并直接复制。
    public func startLastSuccessfulAction() async {
        refreshLastActionAvailability()
        guard case .available(let action) = lastActionAvailability else {
            lastActionBlockReason = lastActionAvailability.blockReason
                ?? "上次处理不可用，请自定义处理。"
            return
        }
        apply(action)
        autoCopyAfterUnpack = true
        await runUnpack()
    }

    private func apply(_ action: LastSuccessfulAction) {
        destinationKind = action.kind
        contentMode = action.contentMode
        pathIsTyped = false
        pathCopyCompletedInBoth = false
        bothPathDescription = nil
        switch action.kind {
        case .path:
            selectedPath = action.path
            selectedDevice = nil
        case .device:
            selectedPath = nil
            selectedDevice = AdbDevice(
                sn: action.deviceSN ?? "",
                brand: action.deviceBrand ?? "",
                model: action.deviceModel ?? ""
            )
        case .both:
            // 按共识：上次不会保存 both；若脏数据则降级为路径优先。
            selectedPath = action.path
            selectedDevice = nil
            destinationKind = .path
        }
    }

    private func runUnpack() async {
        step = .unpacking
        appendLog("开始处理: \(job.fileName)")
        do {
            let service = unpackService
            let zipURL = job.fileURL
            let dbRoot = settings.dbRootDirectoryURL
            let result = try await runOffMain {
                try service.unpack(zipURL: zipURL, dbRoot: dbRoot)
            }
            extractDirectory = result.extractDirectory
            extractHistory.record(
                extractPath: result.extractDirectory.path,
                sourceFileName: job.fileName
            )
            appendLog("解压完成: \(result.extractDirectory.path)")
            if autoCopyAfterUnpack, let mode = contentMode {
                await chooseContentMode(mode)
            } else {
                autoCopyAfterUnpack = false
                step = .chooseDestination
            }
        } catch {
            autoCopyAfterUnpack = false
            errorMessage = error.localizedDescription
            appendLog("失败: \(error.localizedDescription)")
            step = .failure
        }
    }

    public func chooseDestination(_ kind: DestinationKind) {
        destinationKind = kind
        pathCopyCompletedInBoth = false
        bothPathDescription = nil
        partialSuccess = nil
        selectedPath = nil
        selectedDevice = nil
        contentMode = nil
        switch kind {
        case .path, .both:
            step = .choosePath
        case .device:
            step = .chooseDevice
        }
    }

    public func selectPath(_ path: String, typed: Bool) {
        selectedPath = path
        pathIsTyped = typed
        step = .contentMode
    }

    public func selectDevice(_ device: AdbDevice) {
        selectedDevice = device
        if destinationKind == .both, pathCopyCompletedInBoth {
            Task { await performCopy() }
        } else {
            step = .contentMode
        }
    }

    public func chooseContentMode(_ mode: ContentMode) async {
        contentMode = mode
        if mode == .common, let extractDirectory {
            do {
                let collected = try CommonFilesCollector.collect(in: extractDirectory)
                if collected.isEmpty {
                    autoCopyAfterUnpack = false
                    errorMessage = CopyError.noCommonFiles.localizedDescription
                    appendLog(errorMessage ?? "")
                    step = .failure
                    return
                }
            } catch {
                autoCopyAfterUnpack = false
                errorMessage = error.localizedDescription
                step = .failure
                return
            }
        }
        await performCopy()
    }

    public func goBack() {
        switch step {
        case .choosePath:
            step = .chooseDestination
            destinationKind = nil
            pathCopyCompletedInBoth = false
            bothPathDescription = nil
        case .chooseDevice:
            if destinationKind == .both, pathCopyCompletedInBoth {
                finishBothAsPathOnlySuccess()
            } else {
                step = .chooseDestination
                destinationKind = nil
            }
        case .contentMode:
            switch destinationKind {
            case .path, .both:
                step = .choosePath
            case .device:
                step = .chooseDevice
            case .none:
                step = .chooseDestination
            }
        case .partialSuccess:
            step = .chooseDevice
        case .failure:
            if extractDirectory != nil {
                resetToChooseDestination()
            } else {
                step = .confirm
            }
        default:
            break
        }
    }

    public func resetToChooseDestination() {
        destinationKind = nil
        pathCopyCompletedInBoth = false
        bothPathDescription = nil
        selectedPath = nil
        selectedDevice = nil
        contentMode = nil
        partialSuccess = nil
        errorMessage = nil
        step = .chooseDestination
    }

    public func retry() async {
        if extractDirectory == nil {
            await startUnpack()
        } else if contentMode == nil || (selectedPath == nil && selectedDevice == nil) {
            step = .chooseDestination
        } else {
            await performCopy()
        }
    }

    public func retryCopy() async {
        await retry()
    }

    public func retryDeviceAfterPartial() async {
        guard destinationKind == .both, pathCopyCompletedInBoth, selectedDevice != nil else {
            step = .chooseDevice
            return
        }
        await performCopy()
    }

    public func changeDeviceAfterPartial() {
        selectedDevice = nil
        step = .chooseDevice
    }

    private func performCopy() async {
        guard let extractDirectory, let contentMode, let destinationKind else {
            errorMessage = "内部状态不完整"
            step = .failure
            return
        }
        step = .copying
        errorMessage = nil
        do {
            switch destinationKind {
            case .path:
                let destPath = try await copyPathSegment()
                // 上次成功存用户选的基目录，不存 allocate 后的 01/02 落地目录，避免下次再套一层。
                let basePath = selectedPath.map { ($0 as NSString).standardizingPath } ?? destPath
                success = WizardSuccessSummary(
                    extractDirectory: extractDirectory,
                    destinationDescription: destPath,
                    pathDescription: destPath
                )
                persistLastSuccessfulAction(
                    kind: .path,
                    mode: contentMode,
                    path: basePath,
                    device: nil,
                    usedFallback: false
                )
                autoCopyAfterUnpack = false
                step = .success

            case .device:
                let resolve = try await copyDeviceSegment()
                guard let selectedDevice else { throw AdbError.commandFailed("未选设备") }
                let desc = "\(selectedDevice.displayName)\n\(resolve.remoteRoot)"
                success = WizardSuccessSummary(
                    extractDirectory: extractDirectory,
                    destinationDescription: desc,
                    usedDeviceFallback: resolve.usedFallback,
                    deviceDescription: desc
                )
                persistLastSuccessfulAction(
                    kind: .device,
                    mode: contentMode,
                    path: nil,
                    device: selectedDevice,
                    usedFallback: resolve.usedFallback
                )
                autoCopyAfterUnpack = false
                step = .success

            case .both:
                if !pathCopyCompletedInBoth {
                    let destPath = try await copyPathSegment()
                    bothPathDescription = destPath
                    pathCopyCompletedInBoth = true
                    selectedDevice = nil
                    appendLog("本地复制完成，请选择设备继续")
                    autoCopyAfterUnpack = false
                    step = .chooseDevice
                } else {
                    let resolve = try await copyDeviceSegment()
                    guard let selectedDevice else { throw AdbError.commandFailed("未选设备") }
                    let deviceDesc = "\(selectedDevice.displayName)\n\(resolve.remoteRoot)"
                    let pathDesc = bothPathDescription ?? selectedPath ?? ""
                    success = WizardSuccessSummary(
                        extractDirectory: extractDirectory,
                        destinationDescription: "本地：\(pathDesc)\n设备：\(deviceDesc)",
                        usedDeviceFallback: resolve.usedFallback,
                        pathDescription: pathDesc,
                        deviceDescription: deviceDesc
                    )
                    // 共识：双目标成功不写 lastSuccessfulAction
                    autoCopyAfterUnpack = false
                    step = .success
                }
            }
        } catch {
            autoCopyAfterUnpack = false
            let message = error.localizedDescription
            appendLog("复制失败: \(message)")
            if destinationKind == .both, pathCopyCompletedInBoth {
                partialSuccess = WizardPartialSuccessSummary(
                    extractDirectory: extractDirectory,
                    pathDescription: bothPathDescription ?? selectedPath ?? "",
                    deviceError: message
                )
                step = .partialSuccess
            } else {
                errorMessage = message
                step = .failure
            }
        }
    }

    private func copyPathSegment() async throws -> String {
        guard let selectedPath else {
            throw CopyError.createDirectoryFailed(URL(fileURLWithPath: "/"), "未选路径")
        }
        guard let extractDirectory, let contentMode else {
            throw CopyError.createDirectoryFailed(URL(fileURLWithPath: "/"), "内部状态不完整")
        }
        let base = URL(fileURLWithPath: (selectedPath as NSString).standardizingPath)
        let actual = try await copyLocal(mode: contentMode, extract: extractDirectory, destBase: base)
        if !pathIsTyped || history.isPathKnown(base.path) {
            history.touchPath(base.path)
            needsRememberPrompt = false
        } else {
            needsRememberPrompt = true
        }
        appendLog("本地复制完成: \(actual.path)")
        return actual.path
    }

    private func copyDeviceSegment() async throws -> AdbResolveResult {
        guard let selectedDevice else { throw AdbError.commandFailed("未选设备") }
        guard let extractDirectory, let contentMode else { throw AdbError.commandFailed("内部状态不完整") }
        let resolve = try await copyDevice(mode: contentMode, extract: extractDirectory, device: selectedDevice)
        history.touchDevice(sn: selectedDevice.sn, brand: selectedDevice.brand, model: selectedDevice.model)
        appendLog("设备推送完成: \(selectedDevice.displayName) → \(resolve.remoteRoot)")
        return resolve
    }

    private func finishBothAsPathOnlySuccess() {
        guard let extractDirectory else { return }
        let actualPath = bothPathDescription ?? selectedPath ?? ""
        let basePath = selectedPath.map { ($0 as NSString).standardizingPath } ?? actualPath
        success = WizardSuccessSummary(
            extractDirectory: extractDirectory,
            destinationDescription: actualPath,
            pathDescription: actualPath
        )
        if let contentMode, !basePath.isEmpty {
            persistLastSuccessfulAction(
                kind: .path,
                mode: contentMode,
                path: basePath,
                device: nil,
                usedFallback: false
            )
        }
        destinationKind = .path
        step = .success
    }

    private func persistLastSuccessfulAction(
        kind: DestinationKind,
        mode: ContentMode,
        path: String?,
        device: AdbDevice?,
        usedFallback: Bool
    ) {
        guard kind == .path || kind == .device else { return }
        let action = LastSuccessfulAction(
            kind: kind,
            contentMode: mode,
            path: path,
            deviceSN: device?.sn,
            deviceBrand: device?.brand,
            deviceModel: device?.model,
            usedDeviceFallback: usedFallback,
            ts: Int(Date().timeIntervalSince1970)
        )
        history.saveLastSuccessfulAction(action)
    }

    public func confirmRememberPath(_ remember: Bool) {
        guard let selectedPath else { return }
        let path = (selectedPath as NSString).standardizingPath
        if remember {
            history.touchPath(path)
        }
    }

    private func copyLocal(mode: ContentMode, extract: URL, destBase: URL) async throws -> URL {
        let localCopy = self.localCopy
        return try await runOffMain {
            switch mode {
            case .common:
                let collected = try CommonFilesCollector.collect(in: extract)
                guard !collected.isEmpty else { throw CopyError.noCommonFiles }
                return try localCopy.copyCommonFiles(collected.files, to: destBase)
            case .tree:
                return try localCopy.copyTreeChildren(from: extract, to: destBase)
            }
        }
    }

    private func copyDevice(mode: ContentMode, extract: URL, device: AdbDevice) async throws -> AdbResolveResult {
        let adb = makeAdb()
        let service = DeviceCopyService(adb: adb)
        return try await runOffMain {
            switch mode {
            case .common:
                let collected = try CommonFilesCollector.collect(in: extract)
                guard !collected.isEmpty else { throw CopyError.noCommonFiles }
                return try service.copyCommonFiles(collected.files, sn: device.sn)
            case .tree:
                return try service.copyTreeChildren(from: extract, sn: device.sn)
            }
        }
    }
}

private func runOffMain<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
