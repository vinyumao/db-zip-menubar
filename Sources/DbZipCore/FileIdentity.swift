import Foundation

/// 忽略身份：标准化路径 + size + mtime。
public struct FileIdentity: Codable, Hashable, Sendable, Equatable {
    public var path: String
    public var fileSize: Int64
    public var mtime: TimeInterval

    public init(path: String, fileSize: Int64, mtime: TimeInterval) {
        self.path = Self.normalizePath(path)
        self.fileSize = fileSize
        self.mtime = mtime
    }

    public init(url: URL, fileManager: FileManager = .default) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        self.init(path: url.path, fileSize: Int64(size), mtime: mtime)
    }

    public static func normalizePath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
