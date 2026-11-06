import AppKit
import DbZipCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            Button(appModel.pendingJobs.isEmpty ? "待处理…" : "待处理 (\(appModel.pendingCount))…") {
                openWindow(id: "pending")
                WindowFront.scheduleRaise()
            }

            Button(appModel.extractSessions.isEmpty ? "解压历史…" : "解压历史 (\(appModel.extractSessions.count))…") {
                appModel.refreshExtractSessions()
                openWindow(id: "extractHistory")
                WindowFront.scheduleRaise()
            }

            Button("选择 zip…") {
                appModel.chooseZipManually()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if appModel.activeCoordinator != nil {
                        openWindow(id: "wizard")
                        WindowFront.scheduleRaise()
                    }
                }
            }

            Divider()

            if appModel.watchingStarting {
                Text("正在检查目录访问…")
            }
            if appModel.settings.watchingEnabled {
                Button("暂停监听") { appModel.stopWatching() }
            } else {
                Button("开始监听") { appModel.startWatching() }
            }

            Button("设置…") {
                openSettings()
                WindowFront.scheduleRaise()
            }

            Divider()

            Button("退出") {
                appModel.requestQuit()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWizardWindow)) { _ in
            openWindow(id: "wizard")
            WindowFront.scheduleRaise()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPendingListWindow)) { _ in
            openWindow(id: "pending")
            WindowFront.scheduleRaise()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openExtractHistoryWindow)) { _ in
            openWindow(id: "extractHistory")
            WindowFront.scheduleRaise()
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { appModel.pendingUserMessage != nil },
                set: { if !$0 { appModel.pendingUserMessage = nil } }
            )
        ) {
            Button("打开解压历史") {
                appModel.pendingUserMessage = nil
                appModel.refreshExtractSessions()
                openWindow(id: "extractHistory")
                WindowFront.scheduleRaise()
            }
            Button("好", role: .cancel) {
                appModel.pendingUserMessage = nil
            }
        } message: {
            Text(appModel.pendingUserMessage ?? "")
        }
        .alert(
            "不符合匹配规则",
            isPresented: Binding(
                get: { appModel.manualMismatch != nil },
                set: { if !$0 { appModel.manualMismatch = nil } }
            )
        ) {
            Button("仍要处理") {
                appModel.forceProcessMismatchedZip()
                openWindow(id: "wizard")
                WindowFront.scheduleRaise()
            }
            Button("取消", role: .cancel) {
                appModel.manualMismatch = nil
            }
        } message: {
            Text(appModel.manualMismatch?.reason ?? "")
        }
    }
}
