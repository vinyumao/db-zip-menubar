import Foundation

public enum ContentMode: String, Sendable, Codable {
    case common
    case tree
}

public struct CollectedCommonFiles: Sendable, Equatable {
    public var files: [URL]
    public var dbFile: URL?
    public var siFile: URL?
    public var logDate: String?
    public var logFiles: [URL]

    public var isEmpty: Bool { files.isEmpty }

    public init(files: [URL], dbFile: URL?, siFile: URL?, logDate: String?, logFiles: [URL]) {
        self.files = files
        self.dbFile = dbFile
        self.siFile = siFile
        self.logDate = logDate
        self.logFiles = logFiles
    }
}

/// 对齐旧脚本 `collect_common_files`：仅一层。
public enum CommonFilesCollector {
    private static let logPattern = #"_d([0-9]{8})(_[0-9]+)?\.log$"#

    public static func collect(in root: URL, fileManager: FileManager = .default) throws -> CollectedCommonFiles {
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var dbFile: URL?
        var dbMtime: Date = .distantPast
        var siFile: URL?
        var siMtime: Date = .distantPast
        var logCandidates: [(url: URL, date: String)] = []

        for url in entries {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            let mtime = values.contentModificationDate ?? .distantPast

            if isDBFile(name) {
                if mtime >= dbMtime {
                    dbMtime = mtime
                    dbFile = url
                }
            } else if name.lowercased().hasSuffix(".si") {
                if mtime >= siMtime {
                    siMtime = mtime
                    siFile = url
                }
            } else if name.lowercased().hasSuffix(".log"), let date = logDate(from: name) {
                logCandidates.append((url, date))
            }
        }

        let latestDate = logCandidates.map(\.date).max()
        let logFiles: [URL]
        if let latestDate {
            logFiles = logCandidates.filter { $0.date == latestDate }.map(\.url)
        } else {
            logFiles = []
        }

        var files: [URL] = []
        if let dbFile { files.append(dbFile) }
        if let siFile { files.append(siFile) }
        files.append(contentsOf: logFiles)

        return CollectedCommonFiles(
            files: files,
            dbFile: dbFile,
            siFile: siFile,
            logDate: latestDate,
            logFiles: logFiles
        )
    }

    public static func isDBFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".db")
    }

    public static func logDate(from name: String) -> String? {
        guard let match = name.range(of: logPattern, options: .regularExpression) else {
            return nil
        }
        let matched = String(name[match])
        guard let dateRange = matched.range(of: #"[0-9]{8}"#, options: .regularExpression) else {
            return nil
        }
        return String(matched[dateRange])
    }
}
