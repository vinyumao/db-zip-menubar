import AppKit
import DbZipCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var draft: AppSettings = AppSettings()
    @State private var cleanupScope: DbCleanupScope = .olderThanOneMonth
    @State private var confirmCleanup = false
    @State private var cleanupPlan: DbCleanupPlan?
    @State private var cleanupBusy = false
    @State private var cleanupResultText: String?

    var body: some View {
        Form {
            Section("目录") {
                HStack {
                    TextField("监听目录", text: $draft.watchDirectory)
                    Button("选择…") { pickDirectory { draft.watchDirectory = $0 } }
                }
                HStack {
                    TextField("db 根目录", text: $draft.dbRootDirectory)
                    Button("选择…") { pickDirectory { draft.dbRootDirectory = $0 } }
                }
            }

            Section("清理已解压内容") {
                Text("仅删除 db 根下的 yyyyMMdd 日期目录，不删 zip 源站下载区其它文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("范围", selection: $cleanupScope) {
                    ForEach(DbCleanupScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Text(cleanupScope.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("清理…") {
                    prepareCleanup()
                }
                .disabled(cleanupBusy || appModel.activeCoordinator != nil)
                if appModel.activeCoordinator != nil { Text("请先结束当前处理流程再清理。").font(.caption).foregroundStyle(.secondary) }
            }

            Section("ADB") {
                HStack {
                    TextField("adb 路径（可空，自动查找）", text: Binding(
                        get: { draft.adbPath ?? "" },
                        set: { draft.adbPath = $0.isEmpty ? nil : $0 }
                    ))
                    Button("浏览…") { pickFile { draft.adbPath = $0 } }
                }
            }

            Section("行为") {
                Toggle("登录时打开", isOn: $draft.openAtLogin)
                Toggle("启用监听", isOn: $draft.watchingEnabled)
                HStack {
                    Text("下载完成判定：文件大小稳定满")
                    TextField("", value: $draft.stabilitySeconds, format: .number.precision(.fractionLength(1)))
                        .frame(width: 52)
                    Text("秒后入队")
                        .foregroundStyle(.secondary)
                }
            }

            Section("处理预设") {
                if appModel.presets.isEmpty {
                    Text("在复制预览或成功页保存常用的处理方案。").foregroundStyle(.secondary)
                }
                ForEach(appModel.presets) { preset in
                    HStack {
                        Text(preset.name)
                        Spacer()
                        Button("删除", role: .destructive) { appModel.deletePreset(preset) }
                    }
                }
            }

            Section("关于") {
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                Button("打开 Application Support") {
                    appModel.openAppSupport()
                }
            }

            if let hint = appModel.showSettingsHint {
                Text(hint).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("还原默认") {
                    draft = AppSettings()
                }
                Button("保存") {
                    appModel.saveSettings(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 620, height: 680)
        .onAppear { draft = appModel.settings }
        .confirmationDialog(
            cleanupConfirmTitle,
            isPresented: $confirmCleanup,
            titleVisibility: .visible
        ) {
            Button("删除 \(cleanupPlan?.folders.count ?? 0) 个目录", role: .destructive) {
                runCleanup()
            }
            Button("取消", role: .cancel) {
                cleanupPlan = nil
            }
        } message: {
            Text(cleanupConfirmMessage)
        }
        .alert(
            "清理结果",
            isPresented: Binding(
                get: { cleanupResultText != nil },
                set: { if !$0 { cleanupResultText = nil } }
            )
        ) {
            Button("好", role: .cancel) { cleanupResultText = nil }
        } message: {
            Text(cleanupResultText ?? "")
        }
    }

    private var cleanupConfirmTitle: String {
        "确认清理「\(cleanupScope.title)」？"
    }

    private var cleanupConfirmMessage: String {
        guard let plan = cleanupPlan else { return "" }
        if plan.isEmpty {
            return "没有匹配的日期目录。"
        }
        let names = plan.folders.prefix(8).map(\.lastPathComponent).joined(separator: "、")
        let more = plan.folders.count > 8 ? " 等共 \(plan.folders.count) 个" : ""
        return "将永久删除：\(names)\(more)\n\n\(cleanupScope.detail)。处理流程结束后才能执行清理。"
    }

    private func prepareCleanup() {
        // 用设置草稿里的 db 根，避免未保存就清错目录
        let root = URL(fileURLWithPath: (draft.dbRootDirectory as NSString).standardizingPath)
        let excluding = appModel.activeCoordinator?.extractDirectory?.path
        do {
            let plan = try DbRootCleanup.plan(
                dbRoot: root,
                scope: cleanupScope,
                excludingPathPrefix: excluding
            )
            cleanupPlan = plan
            if plan.isEmpty {
                cleanupResultText = "没有匹配「\(cleanupScope.title)」的日期目录可删。"
            } else {
                confirmCleanup = true
            }
        } catch {
            cleanupResultText = "扫描失败：\(error.localizedDescription)"
        }
    }

    private func runCleanup() {
        guard let plan = cleanupPlan, !plan.isEmpty, appModel.activeCoordinator == nil else {
            cleanupResultText = "请先结束当前处理流程，再清理目录。"
            return
        }
        cleanupBusy = true
        appModel.maintenanceBusy = true
        // Revalidate against the current wizard, not just the confirmation snapshot.
        let protected = appModel.activeCoordinator?.extractDirectory?.standardizedFileURL.path
        let safe = DbCleanupPlan(folders: plan.folders.filter { folder in
            guard let protected else { return true }
            return protected != folder.path && !protected.hasPrefix(folder.path + "/")
        }, scope: plan.scope)
        Task {
            defer {
                cleanupBusy = false
                appModel.maintenanceBusy = false
                cleanupPlan = nil
                appModel.refreshExtractSessions()
            }
            let result = try? await runInBackground { DbRootCleanup.execute(plan: safe) }
            guard let result else { cleanupResultText = "清理未完成"; return }
            var parts = ["已删除 \(result.deleted.count) 个目录。"]
            if !result.failed.isEmpty {
                parts.append("失败：" + result.failed.map { "\($0.path)：\($0.message)" }.joined(separator: "\n"))
            }
            cleanupResultText = parts.joined(separator: "\n")
        }
    }

    private func pickDirectory(onPick: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url.path)
        }
    }

    private func pickFile(onPick: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url.path)
        }
    }
}
