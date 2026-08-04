import AppKit
import SwiftUI

/// 菜单栏 App（LSUIElement）打开窗口时强制激活并临时浮在普通窗口之上。
enum WindowFront {
    static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// openWindow 后窗口可能尚未创建，短重试置顶。
    static func scheduleRaise(retries: Int = 10, interval: TimeInterval = 0.05) {
        activateApp()
        func attempt(_ left: Int) {
            raiseOurWindows()
            guard left > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                attempt(left - 1)
            }
        }
        DispatchQueue.main.async {
            attempt(retries)
        }
    }

    static func raiseOurWindows() {
        activateApp()
        for window in NSApp.windows where isUtilityWindow(window) {
            configureFloating(window)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// 关闭「待处理」窗口（若当前已打开）。
    static func closePendingWindow() {
        for window in NSApp.windows where isPendingWindow(window) {
            window.close()
        }
    }

    /// 关闭 Wizard 窗口（若当前已打开）。
    static func closeWizardWindow() {
        for window in NSApp.windows where isWizardWindow(window) {
            window.close()
        }
    }

    private static func isPendingWindow(_ window: NSWindow) -> Bool {
        if let id = window.identifier?.rawValue.lowercased(), id.contains("pending") {
            return true
        }
        return window.title.contains("待处理")
    }

    private static func isWizardWindow(_ window: NSWindow) -> Bool {
        if let id = window.identifier?.rawValue.lowercased(), id.contains("wizard") {
            return true
        }
        let title = window.title
        return title.localizedCaseInsensitiveContains("wizard")
            || title == "DB Zip Wizard"
    }

    static func configureFloating(_ window: NSWindow) {
        window.level = .floating
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        window.isMovableByWindowBackground = true
    }

    private static func isUtilityWindow(_ window: NSWindow) -> Bool {
        // 排除菜单栏自身、不可见窗
        guard window.isVisible || window.isMiniaturized else { return false }
        if window.styleMask.contains(.nonactivatingPanel) { return false }
        if window.frame.width < 80 || window.frame.height < 80 { return false }

        if let id = window.identifier?.rawValue.lowercased() {
            if id == "wizard" || id == "pending" || id == "extracthistory" { return true }
            if id.contains("settings") || id.contains("preference") { return true }
        }

        let title = window.title
        if title.contains("待处理") { return true }
        if title.contains("解压历史") { return true }
        if title.localizedCaseInsensitiveContains("wizard") { return true }
        if title.contains("设置") || title.localizedCaseInsensitiveContains("settings") { return true }
        if title.contains("DB Zip") { return true }
        return false
    }
}

/// 挂到窗口根视图：出现时置顶并保持 floating。
struct RaiseWindowOnAppear: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window in
                WindowFront.configureFloating(window)
                WindowFront.activateApp()
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            })
            .onAppear {
                WindowFront.scheduleRaise()
            }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

extension View {
    func raiseWindowOnAppear() -> some View {
        modifier(RaiseWindowOnAppear())
    }
}
