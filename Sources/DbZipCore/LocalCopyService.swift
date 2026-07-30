import Foundation

public enum CopyError: LocalizedError, Sendable {
    case createDirectoryFailed(URL, String)
    case copyFailed(URL, URL, String)
    case emptySource
    case noCommonFiles

    public var errorDescription: String? {
        switch self {
        case .createDirectoryFailed(let url, let message):
            return "创建目标目录失败 \(url.path): \(message)"
        case .copyFailed(let from, let to, let message):
            return "复制失败 \(from.lastPathComponent) → \(to.path): \(message)"
        case .emptySource:
            return "解压目录为空，无内容可复制"
        case .noCommonFiles:
            return "没有可复制的常用文件"
        }
    }
}

public struct LocalCopyService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// 在 `destinationBase` 下分配 `01`/`02`… 子目录后复制常用文件，返回实际目标目录。
    @discardableResult
    public func copyCommonFiles(_ files: [URL], to destinationBase: URL) throws -> URL {
        guard !files.isEmpty else { throw CopyError.noCommonFiles }
        let destination = try allocateRunDirectory(under: destinationBase)
        for file in files {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            do {
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: file, to: target)
            } catch {
                throw CopyError.copyFailed(file, destination, error.localizedDescription)
            }
        }
        return destination
    }

    /// 在 `destinationBase` 下分配编号子目录后复制整树子项，返回实际目标目录。
    @discardableResult
    public func copyTreeChildren(from source: URL, to destinationBase: URL) throws -> URL {
        let destination = try allocateRunDirectory(under: destinationBase)
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard !children.isEmpty else { throw CopyError.emptySource }
        for item in children {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            do {
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: item, to: target)
            } catch {
                throw CopyError.copyFailed(item, destination, error.localizedDescription)
            }
        }
        return destination
    }

    /// 无数字文件夹 → `01`；最大编号为空则复用，否则 +1。
    public func allocateRunDirectory(under base: URL) throws -> URL {
        try ensureDirectory(base)
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).map(\.lastPathComponent)
        } catch {
            throw CopyError.createDirectoryFailed(base, error.localizedDescription)
        }

        let folder = RunFolderAllocator.nextFolderName(existingNames: names) { name in
            isDirectoryEmpty(base.appendingPathComponent(name, isDirectory: true))
        }
        let run = base.appendingPathComponent(folder, isDirectory: true)
        try ensureDirectory(run)
        return run
    }

    private func isDirectoryEmpty(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let contents = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        return contents.isEmpty
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw CopyError.createDirectoryFailed(url, error.localizedDescription)
        }
    }
}
