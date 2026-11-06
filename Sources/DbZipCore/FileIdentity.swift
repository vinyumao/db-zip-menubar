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
        // URL resource values are cached on the URL instance. Pending jobs and
        // extraction validation must observe the current file on every call.
        let values = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = values[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        let mtime = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        self.init(path: url.path, fileSize: size.int64Value, mtime: mtime)
    }

    public static func normalizePath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
