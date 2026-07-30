import AppKit
import Foundation

/// 收敛对受保护目录（如下载）的访问，避免 TCC 弹窗风暴。
public enum FolderAccess {
    public enum ProbeResult: Equatable {
        case accessible
        case denied
        case missing
    }

    /// 单次探测；不要在定时器里反复调用未授权路径。
    public static func probe(_ directory: URL, fileManager: FileManager = .default) -> ProbeResult {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return .missing
        }
        do {
            _ = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            return .accessible
        } catch {
            return .denied
        }
    }

    /// 通过系统「打开」面板获得一次明确授权（比静默轮询更稳）。
    @MainActor
    public static func requestAccessViaOpenPanel(
        targeting directory: URL,
        message: String = "请选择要监听的文件夹（默认「下载」），以授权访问权限"
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.message = message
        panel.prompt = "授权并选择"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}
