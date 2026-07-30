import AppKit
import DbZipCore
import SwiftUI

struct WizardRootView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let coordinator = appModel.activeCoordinator {
                WizardFlowView(coordinator: coordinator)
                    .environmentObject(appModel)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 12) {
                    Text("没有进行中的任务")
                        .font(.headline)
                    Text("从「待处理」列表或通知打开一项。")
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(width: 480)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWizardWindow)) { _ in
            openWindow(id: "wizard")
            WindowFront.scheduleRaise()
        }
    }
}

struct WizardFlowView: View {
    @ObservedObject var coordinator: WizardCoordinator
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WizardProgressHeader(step: coordinator.step, title: titleForStep)
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 520, maxWidth: 720, alignment: .topLeading)
        .frame(maxHeight: 780, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var titleForStep: String {
        switch coordinator.step {
        case .confirm: return "确认文件"
        case .unpacking: return "解压中"
        case .chooseDestination: return "选择复制位置"
        case .contentMode: return "内容模式"
        case .choosePath: return "选择路径"
        case .chooseDevice:
            return coordinator.pathCopyCompletedInBoth ? "选择设备（第二步）" : "选择设备"
        case .copying: return "复制中"
        case .success: return "完成"
        case .partialSuccess: return "部分完成"
        case .failure: return "失败"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.step {
        case .confirm:
            ConfirmStepView(coordinator: coordinator)
        case .unpacking, .copying:
            ProgressStepView(coordinator: coordinator)
        case .chooseDestination:
            DestinationStepView(coordinator: coordinator)
        case .contentMode:
            ContentModeStepView(coordinator: coordinator)
        case .choosePath:
            PathStepView(coordinator: coordinator)
        case .chooseDevice:
            DeviceStepView(coordinator: coordinator)
        case .success:
            SuccessStepView(coordinator: coordinator)
        case .partialSuccess:
            PartialSuccessStepView(coordinator: coordinator)
        case .failure:
            FailureStepView(coordinator: coordinator)
        }
    }
}

// MARK: - Chrome

private struct WizardProgressHeader: View {
    let step: WizardStep
    let title: String

    private var index: Int {
        switch step {
        case .confirm: return 0
        case .unpacking: return 0
        case .chooseDestination, .choosePath, .chooseDevice: return 1
        case .contentMode, .copying: return 2
        case .success, .partialSuccess, .failure: return 2
        }
    }

    private var hint: String {
        switch step {
        case .confirm, .unpacking: return "确认"
        case .chooseDestination, .choosePath, .chooseDevice: return "复制目标"
        case .contentMode, .copying, .success, .partialSuccess, .failure: return "内容模式"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(dotColor(i))
                        .frame(width: 7, height: 7)
                        .shadow(color: i == index ? Color.accentColor.opacity(0.35) : .clear, radius: 3)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor, Color.teal],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 2)
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.title3.weight(.semibold))
        }
        .padding(.bottom, 8)
    }

    private var progress: CGFloat {
        switch index {
        case 0: return 0.22
        case 1: return 0.55
        default: return 0.85
        }
    }

    private func dotColor(_ i: Int) -> Color {
        if i < index { return .teal }
        if i == index { return .accentColor }
        return Color.secondary.opacity(0.35)
    }
}

private struct FileIdentityCard: View {
    let fileName: String
    let path: String
    let mismatchReason: String?
    let forced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.23, green: 0.51, blue: 0.96), Color.teal],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .shadow(color: Color.teal.opacity(0.28), radius: 8, y: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(shortName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .help(fileName)
                    Text("ZIP · \(folderHint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                statusPill
            }

            VStack(alignment: .leading, spacing: 8) {
                Divider().opacity(0.5)
                SegmentedFileNameView(fileName: fileName)
                HStack(spacing: 8) {
                    Text(abbrevPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    Button("复制路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private var shortName: String {
        guard fileName.count > 28 else { return fileName }
        return "\(fileName.prefix(14))…\(fileName.suffix(12))"
    }

    private var abbrevPath: String {
        LastSuccessfulAction.abbrevPath(path)
    }

    private var folderHint: String {
        let parent = (path as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent
    }

    @ViewBuilder
    private var statusPill: some View {
        if let mismatchReason {
            Text(forced ? "强制" : "有问题")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.12), in: Capsule())
                .help(mismatchReason)
        } else {
            Text("已匹配")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.1, green: 0.62, blue: 0.43))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12), in: Capsule())
        }
    }
}

private struct SegmentedFileNameView: View {
    let fileName: String

    var body: some View {
        Text(attributed)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let lower = fileName.lowercased()
        guard lower.hasSuffix(".zip") else {
            return AttributedString(fileName)
        }
        let base = String(fileName.dropLast(4))
        let ext = String(fileName.suffix(fileName.count - base.count))
        let parts = base.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        for (idx, part) in parts.enumerated() {
            if idx > 0 {
                var sep = AttributedString("_")
                sep.foregroundColor = .secondary
                result.append(sep)
            }
            var piece = AttributedString(part)
            if part.range(of: #"^[0-9]{9}$"#, options: .regularExpression) != nil {
                piece.foregroundColor = .accentColor
                piece.font = .system(.caption, design: .monospaced).weight(.bold)
            } else if part.range(of: #"^[0-9]{10,}$"#, options: .regularExpression) != nil {
                piece.foregroundColor = .teal
                piece.font = .system(.caption, design: .monospaced).weight(.bold)
            } else {
                piece.foregroundColor = .secondary
            }
            result.append(piece)
        }
        var zip = AttributedString(ext)
        zip.foregroundColor = .primary
        zip.font = .system(.caption, design: .monospaced).weight(.bold)
        result.append(zip)
        return result
    }
}

private struct ChoiceCardButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Button styles

/// 白底描边：稍后 / 自定义处理
private struct WizardWhiteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.9), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// 弱化文字按钮：忽略（与白底按钮区分）
private struct WizardGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.clear)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Steps

struct ConfirmStepView: View {
    @ObservedObject var coordinator: WizardCoordinator
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FileIdentityCard(
                fileName: coordinator.job.fileName,
                path: coordinator.job.identity.path,
                mismatchReason: coordinator.mismatchReason,
                forced: coordinator.job.forced
            )

            if let reason = coordinator.lastActionBlockReason,
               case .unavailable = coordinator.lastActionAvailability {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button("忽略") { appModel.handleIgnore() }
                    .buttonStyle(WizardGhostButtonStyle())
                Button("稍后") { appModel.handleLater() }
                    .buttonStyle(WizardWhiteButtonStyle())
                Spacer(minLength: 8)
                trailingActions
            }
            .padding(.top, 4)
        }
        .onAppear { coordinator.refreshLastActionAvailability() }
    }

    @ViewBuilder
    private var trailingActions: some View {
        switch coordinator.lastActionAvailability {
        case .none:
            Button("处理") {
                Task { await coordinator.startUnpack() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)

        case .available(let action):
            Button("自定义处理") {
                Task { await coordinator.startUnpack() }
            }
            .buttonStyle(WizardWhiteButtonStyle())
            Button {
                Task { await coordinator.startLastSuccessfulAction() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("按上次处理").fontWeight(.semibold)
                    Text(action.summaryLine)
                        .font(.caption2)
                        .lineLimit(1)
                        .opacity(0.9)
                }
                .padding(.vertical, 2)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)

        case .unavailable(let action, _):
            Button {
                Task { await coordinator.startLastSuccessfulAction() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("按上次处理").fontWeight(.semibold)
                    Text(action.summaryLine)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }
            .disabled(true)
            .buttonStyle(WizardWhiteButtonStyle())
            Button("自定义处理") {
                Task { await coordinator.startUnpack() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }
}

struct ProgressStepView: View {
    @ObservedObject var coordinator: WizardCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView()
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(Array(coordinator.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .frame(height: min(80 + CGFloat(coordinator.logLines.count) * 16, 220))
        }
    }
}

struct DestinationStepView: View {
    @ObservedObject var coordinator: WizardCoordinator
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("解压已完成，接下来复制到哪里？")
                .foregroundStyle(.secondary)
                .font(.callout)
            if let dir = coordinator.extractDirectory {
                Text(LastSuccessfulAction.abbrevPath(dir.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ChoiceCardButton(
                title: "指定路径",
                subtitle: "本地目录 · 每次写入 01/02… 子目录",
                systemImage: "folder"
            ) {
                coordinator.chooseDestination(.path)
            }
            ChoiceCardButton(
                title: "指定设备",
                subtitle: "ADB 已连接设备",
                systemImage: "iphone"
            ) {
                coordinator.chooseDestination(.device)
            }
            ChoiceCardButton(
                title: "两个都执行",
                subtitle: "先本地路径，再 ADB 设备 · 共用内容模式",
                systemImage: "arrow.left.arrow.right"
            ) {
                coordinator.chooseDestination(.both)
            }
            HStack {
                if let dir = coordinator.extractDirectory {
                    Button("打开解压目录") { NSWorkspace.shared.open(dir) }
                        .buttonStyle(.bordered)
                }
                Spacer(minLength: 8)
                Button("取消") { appModel.handleCancelCopyKeepExtract() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
    }
}

struct ContentModeStepView: View {
    @ObservedObject var coordinator: WizardCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("要复制哪些内容？")
                .foregroundStyle(.secondary)
                .font(.callout)
            ChoiceCardButton(
                title: "常用文件",
                subtitle: "db + si + 最新日期日志分片",
                systemImage: "sparkles"
            ) {
                Task { await coordinator.chooseContentMode(.common) }
            }
            ChoiceCardButton(
                title: "整目录",
                subtitle: "仅子文件 / 子文件夹",
                systemImage: "square.stack.3d.up"
            ) {
                Task { await coordinator.chooseContentMode(.tree) }
            }
            Button("返回") { coordinator.goBack() }
                .padding(.top, 8)
        }
    }
}

struct PathStepView: View {
    @ObservedObject var coordinator: WizardCoordinator
    @EnvironmentObject private var appModel: AppModel
    @State private var typedPath = ""

    var body: some View {
        let paths = appModel.history.listPaths()
        VStack(alignment: .leading, spacing: 12) {
            if paths.isEmpty {
                Text("尚未配置过本地路径。")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(paths, id: \.path) { item in
                            Button {
                                coordinator.selectPath(item.path, typed: false)
                            } label: {
                                Text(item.isLast ? "（上次）\(item.path)" : item.path)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if item.path != paths.last?.path {
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(max(paths.count, 1)) * 40 + 8, 260))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            HStack {
                TextField("其他路径", text: $typedPath)
                Button("使用") {
                    let expanded = (typedPath as NSString).expandingTildeInPath
                    guard !expanded.isEmpty else { return }
                    coordinator.selectPath(expanded, typed: true)
                }
            }

            Button("返回") { coordinator.goBack() }
        }
    }
}

struct DeviceStepView: View {
    @ObservedObject var coordinator: WizardCoordinator
    @EnvironmentObject private var appModel: AppModel
    @State private var devices: [AdbDevice] = []
    @State private var unavailable = 0
    @State private var errorText: String?
    @State private var loading = false

    private var isBothSecondStep: Bool {
        coordinator.destinationKind == .both && coordinator.pathCopyCompletedInBoth
    }

    private var deviceListHeight: CGFloat {
        let rows = max(devices.count, 1)
        return min(CGFloat(rows) * 44 + 8, 280)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isBothSecondStep {
                Text("本地已复制完成，请选择要推送的设备（内容模式与本地相同）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red)
                Button("打开设置") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    WindowFront.scheduleRaise()
                }
            }
            if unavailable > 0 {
                Text("另有 \(unavailable) 台设备不可用，未列入选项")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            if loading {
                ProgressView("刷新设备…")
            } else if devices.isEmpty && errorText == nil {
                Text("当前没有可用 ADB 设备。")
                    .foregroundStyle(.secondary)
            } else {
                let lastSN = appModel.history.lastDeviceSN()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(devices) { device in
                            Button {
                                coordinator.selectDevice(device)
                            } label: {
                                Text(device.sn == lastSN ? "\(device.displayName)（上次）" : device.displayName)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 10)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if device.id != devices.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: deviceListHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
            HStack {
                Button("刷新") { refresh() }
                    .buttonStyle(.bordered)
                Spacer(minLength: 8)
                Button(isBothSecondStep ? "跳过设备并完成" : "返回") {
                    coordinator.goBack()
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        loading = true
        errorText = nil
        Task {
            do {
                let adb = AdbClient(configuredPath: appModel.settings.adbPath)
                let result = try adb.listReadyDevices()
                devices = result.devices
                unavailable = result.unavailableCount
            } catch {
                errorText = error.localizedDescription
                devices = []
            }
            loading = false
        }
    }
}

struct SuccessStepView: View {
    @ObservedObject var coordinator: WizardCoordinator
    @EnvironmentObject private var appModel: AppModel
    @State private var promptCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("复制完成").font(.title2.weight(.semibold))
            if let success = coordinator.success {
                if let path = success.pathDescription, let device = success.deviceDescription {
                    labeledBlock(title: "本地", value: path)
                    labeledBlock(title: "设备", value: device)
                } else if let path = success.pathDescription {
                    Text(path)
                        .textSelection(.enabled)
                } else {
                    Text(success.destinationDescription)
                        .textSelection(.enabled)
                }
                if success.usedDeviceFallback {
                    Text("项目目录不可写，已回退到 /sdcard/db。请手动再拷到项目目录。")
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button("在 Finder 打开解压目录") {
                        NSWorkspace.shared.open(success.extractDirectory)
                    }
                    .buttonStyle(.bordered)
                    if let path = success.pathDescription {
                        Button(promptCopied ? "已复制" : "复制提示词") {
                            copyPosdebugPrompt(for: path)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Button("完成") { appModel.handleWizardFinished() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .alert("是否记住本次输入的地址？", isPresented: Binding(
            get: { coordinator.needsRememberPrompt },
            set: { coordinator.needsRememberPrompt = $0 }
        )) {
            Button("记住") {
                coordinator.confirmRememberPath(true)
                coordinator.needsRememberPrompt = false
            }
            Button("不记住", role: .cancel) {
                coordinator.needsRememberPrompt = false
            }
        }
    }

    private func labeledBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func copyPosdebugPrompt(for path: String) {
        let prompt = "/posdebug 请分析 \(path) 下的文件 "
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        promptCopied = true
    }
}

struct PartialSuccessStepView: View {
    @ObservedObject var coordinator: WizardCoordinator
    @EnvironmentObject private var appModel: AppModel
    @State private var promptCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地已完成，设备失败")
                .font(.title2.weight(.semibold))
            if let partial = coordinator.partialSuccess {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(partial.pathDescription).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("设备错误").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(partial.deviceError).foregroundStyle(.red)
                }
                HStack(spacing: 8) {
                    Button("在 Finder 打开解压目录") {
                        NSWorkspace.shared.open(partial.extractDirectory)
                    }
                    .buttonStyle(.bordered)
                    Button(promptCopied ? "已复制" : "复制提示词") {
                        let prompt = "/posdebug 请分析 \(partial.pathDescription) 下的文件 "
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                        promptCopied = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            HStack {
                Button("重试设备") {
                    Task { await coordinator.retryDeviceAfterPartial() }
                }
                .buttonStyle(.borderedProminent)
                Button("换设备") {
                    coordinator.changeDeviceAfterPartial()
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 8)
                Button("结束") { appModel.handleWizardFinished() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
    }
}

struct FailureStepView: View {
    @ObservedObject var coordinator: WizardCoordinator
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(coordinator.errorMessage ?? "未知错误")
                .foregroundStyle(.red)
            if let dir = coordinator.extractDirectory {
                Text("已解压目录已保留：\(dir.path)")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            HStack {
                Button("重试") {
                    Task { await coordinator.retry() }
                }
                .buttonStyle(.bordered)
                if coordinator.extractDirectory != nil {
                    Button("换目标") {
                        coordinator.resetToChooseDestination()
                    }
                    .buttonStyle(.bordered)
                    if coordinator.destinationKind != nil, !coordinator.pathCopyCompletedInBoth {
                        Button("换内容模式") {
                            coordinator.step = .contentMode
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("在 Finder 打开解压目录") {
                        if let dir = coordinator.extractDirectory {
                            NSWorkspace.shared.open(dir)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 8)
                Button("取消") { appModel.handleCancelCopyKeepExtract() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
    }
}
