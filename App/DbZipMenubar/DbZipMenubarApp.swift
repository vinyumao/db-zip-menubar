import AppKit
import SwiftUI
import DbZipCore

@main
struct DbZipMenubarApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var delegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appModel)
        } label: {
            MenuBarLabel(pendingCount: appModel.pendingCount)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .raiseWindowOnAppear()
        }

        Window("待处理", id: "pending") {
            PendingListView()
                .environmentObject(appModel)
                .raiseWindowOnAppear()
        }
        .defaultSize(width: 480, height: 420)

        Window("解压历史", id: "extractHistory") {
            ExtractHistoryView()
                .environmentObject(appModel)
                .raiseWindowOnAppear()
        }
        .defaultSize(width: 520, height: 460)

        Window("DB Zip Wizard", id: "wizard") {
            WizardRootView()
                .environmentObject(appModel)
                .raiseWindowOnAppear()
        }
        .defaultSize(width: 520, height: 320)
        .windowResizability(.contentSize)
    }
}

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .openPendingListWindow, object: nil)
        return false
    }
}

struct MenuBarLabel: View {
    let pendingCount: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "doc.zipper")
            if pendingCount > 0 {
                Text("\(min(pendingCount, 99))")
                    .font(.caption2.monospacedDigit())
            }
        }
    }
}
