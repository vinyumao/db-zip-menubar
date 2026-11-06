import Foundation
import CryptoKit

public struct ContentItem: Identifiable, Sendable, Equatable {
    public var url: URL
    public var bytes: Int64
    public var isDirectory: Bool
    public var id: String { url.path }
}

public struct ContentPlan: Sendable {
    public var root: URL
    public var items: [ContentItem]
    public var warnings: [String]
    public var logDays: Int
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    public func selectedFiles(ids: Set<String>) throws -> [URL] {
        let selected = items.filter { ids.contains($0.id) }.map(\.url)
        guard !selected.isEmpty else { throw CopyError.emptySource }
        let names = Set(selected.map(\.lastPathComponent))
        for file in selected where file.pathExtension.lowercased() == "db" {
            for suffix in ["-wal", "-shm"] {
                let companion = file.lastPathComponent + suffix
                if items.contains(where: { $0.url.lastPathComponent == companion }), !names.contains(companion) {
                    throw CopyError.invalidSelection("\(file.lastPathComponent) 必须与 \(companion) 一起复制")
                }
            }
        }
        for file in selected where file.lastPathComponent.lowercased().hasSuffix(".db-wal") || file.lastPathComponent.lowercased().hasSuffix(".db-shm") {
            guard names.contains(String(file.lastPathComponent.dropLast(4))) else {
                throw CopyError.invalidSelection("请同时选择 \(file.lastPathComponent) 对应的数据库")
            }
        }
        return selected
    }
}

public enum ContentPlanner {
    public static func make(root: URL, mode: ContentMode, logDays: Int = 5) throws -> ContentPlan {
        let fm = FileManager.default
        var effective = root
        for _ in 0..<8 {
            let children = try fm.contentsOfDirectory(at: effective, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                .filter { $0.lastPathComponent != "__MACOSX" }
            guard children.count == 1 else { break }
            let values = try children[0].resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { break }
            effective = children[0]
        }
        let files: [URL]
        switch mode {
        case .common: files = try CommonFilesCollector.collect(in: effective, logDays: logDays).files
        case .tree:
            files = try fm.contentsOfDirectory(at: effective, includingPropertiesForKeys: nil, options: [])
                .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let items = try files.map { url -> ContentItem in
            let manifest = try FileManifest.entries(at: url)
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            return ContentItem(url: url, bytes: manifest.reduce(0) { $0 + $1.bytes }, isDirectory: isDirectory)
        }
        var warnings: [String] = []
        if effective != root { warnings.append("已识别包装目录：\(effective.lastPathComponent)") }
        if files.contains(where: { $0.lastPathComponent.lowercased().hasSuffix(".db-wal") }) {
            warnings.append("检测到 WAL，已包含数据库配套文件；请确保源端导出时没有并发写入。")
        }
        return ContentPlan(root: effective, items: items, warnings: warnings, logDays: max(1, min(365, logDays)))
    }
}

public struct FileManifestEntry: Sendable {
    public var relativePath: String
    public var url: URL
    public var bytes: Int64

    public func sha256(control: OperationControl? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try control?.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum FileManifest {
    public static func entries(at root: URL) throws -> [FileManifestEntry] {
        let fm = FileManager.default
        var entries: [FileManifestEntry] = []
        func visit(_ url: URL, relative: String) throws {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw CopyError.invalidSelection("不复制符号链接：\(url.lastPathComponent)") }
            if values.isDirectory == true {
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
                }
            } else if values.isRegularFile == true {
                entries.append(FileManifestEntry(relativePath: relative, url: url, bytes: Int64(values.fileSize ?? 0)))
            } else {
                throw CopyError.invalidSelection("不支持的文件类型：\(url.lastPathComponent)")
            }
        }
        try visit(root, relative: "")
        return entries.sorted { $0.relativePath < $1.relativePath }
    }
}
