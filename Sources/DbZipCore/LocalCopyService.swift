import Foundation

public enum CopyError: LocalizedError, Sendable {
    case createDirectoryFailed(URL, String)
    case copyFailed(URL, URL, String)
    case emptySource
    case noCommonFiles
    case invalidSelection(String)

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
        case .invalidSelection(let message): return message
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
        return try copyFiles(files, to: destinationBase)
    }

    @discardableResult
    public func copyTreeChildren(from source: URL, to destinationBase: URL) throws -> URL {
        let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        return try copyFiles(children, to: destinationBase)
    }

    public func copyFiles(_ files: [URL], to base: URL, control: OperationControl? = nil) throws -> URL {
        guard !files.isEmpty else { throw CopyError.emptySource }
        let normalizedBase = base.resolvingSymlinksInPath().standardizedFileURL.path
        for source in files {
            let path = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard normalizedBase != path, !normalizedBase.hasPrefix(path + "/") else {
                throw CopyError.invalidSelection("目标目录不能位于源文件夹内部")
            }
            _ = try FileManifest.entries(at: source)
        }
        try ensureDirectory(base)
        let staging = base.appendingPathComponent(".dbzip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        for (index, file) in files.enumerated() {
            try control?.checkCancellation()
            control?.onProgress("本地复制 \(index + 1)/\(files.count)：\(file.lastPathComponent)")
            let target = staging.appendingPathComponent(file.lastPathComponent)
            do { try fileManager.copyItem(at: file, to: target) }
            catch { throw CopyError.copyFailed(file, target, error.localizedDescription) }
        }
        try control?.checkCancellation()
        let destination = try allocateRunDirectory(under: base)
        // The reserved numbered directory is empty; publish the completed tree in one move.
        try fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
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
