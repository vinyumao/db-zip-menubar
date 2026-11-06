import AppKit
import DbZipCore
import SwiftUI

struct PendingListView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmClear = false
    @State private var clearSkippedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("待处理")
                    .font(.headline)
                Text("\(appModel.pendingCount)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("添加 ZIP…") { appModel.chooseZipManually() }
                if !appModel.presets.isEmpty {
                    Menu("批量预设…") {
                        ForEach(appModel.presets) { preset in
                            Button(preset.name) { appModel.startBatch(preset: preset) }
                        }
                    }
                    .disabled(appModel.pendingJobs.isEmpty || appModel.activeCoordinator != nil)
                }
                Button("清空全部", role: .destructive) {
                    confirmClear = true
                }
                .disabled(appModel.pendingJobs.isEmpty)
            }
            .padding()

            Divider()

            if appModel.pendingJobs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("暂无待处理项")
                        .foregroundStyle(.secondary)
                    Text("可将多个 ZIP 拖到此窗口，或点击「添加 ZIP…」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(appModel.pendingJobs) { job in
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                if appModel.openWizard(for: job) {
                                    openWindow(id: "wizard")
                                    WindowFront.scheduleRaise()
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.fileName)
                                        .font(.body.weight(.medium))
                                        .lineLimit(2)
                                    Text(job.identity.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    HStack(spacing: 8) {
                                        Text(Self.formatFileTime(job.identity.mtime))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                        if job.forced {
                                            Text("强制处理")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                appModel.deletePendingRecord(id: job.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help(appModel.canDeletePending(id: job.id) ? "删除记录" : "任务进行中，无法删除")
                            .disabled(!appModel.canDeletePending(id: job.id))
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .dropDestination(for: URL.self) { urls, _ in
            appModel.enqueueFiles(urls)
            return !urls.isEmpty
        }
        .confirmationDialog("清空全部待处理记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                let skipped = appModel.clearPendingRecords()
                if skipped > 0 {
                    clearSkippedMessage = "已清空其它记录；有 \(skipped) 条正在解压/复制中，已保留。"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除待处理记录，不会删除磁盘上的 zip 文件。正在解压/复制的项会被跳过。")
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { clearSkippedMessage != nil },
                set: { if !$0 { clearSkippedMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { clearSkippedMessage = nil }
        } message: {
            Text(clearSkippedMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPendingListWindow)) { _ in
            openWindow(id: "pending")
            WindowFront.scheduleRaise()
        }
    }

    private static func formatFileTime(_ mtime: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: mtime)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "文件时间 \(formatter.string(from: date))"
    }
}
