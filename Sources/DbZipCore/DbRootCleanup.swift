import Foundation

/// 清理 db 根目录下 `yyyyMMdd` 日期文件夹的范围。
public enum DbCleanupScope: String, CaseIterable, Identifiable, Sendable {
    case olderThanOneMonth
    case olderThanOneWeek
    case olderThanOneDay
    case today
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .olderThanOneMonth: return "一个月前"
        case .olderThanOneWeek: return "一周前"
        case .olderThanOneDay: return "一天前"
        case .today: return "今天"
        case .all: return "所有"
        }
    }

    public var detail: String {
        switch self {
        case .olderThanOneDay: return "删除今天之前的日期目录"
        case .olderThanOneWeek: return "删除早于一周的日期目录"
        case .olderThanOneMonth: return "删除早于一个月的日期目录"
        case .today: return "仅删除今天的日期目录"
        case .all: return "删除 db 根下全部日期目录"
        }
    }
}

public struct DbCleanupPlan: Sendable, Equatable {
    public var folders: [URL]
    public var scope: DbCleanupScope

    public var isEmpty: Bool { folders.isEmpty }

    public init(folders: [URL], scope: DbCleanupScope) {
        self.folders = folders
        self.scope = scope
    }
}

public struct DbCleanupFailure: Sendable, Equatable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct DbCleanupResult: Sendable, Equatable {
    public var deleted: [URL]
    public var failed: [DbCleanupFailure]

    public init(deleted: [URL], failed: [DbCleanupFailure]) {
        self.deleted = deleted
        self.failed = failed
    }
}

public enum DbRootCleanup {
    private static let dayFolderPattern = #"^[0-9]{8}$"#

    public static func isDayFolderName(_ name: String) -> Bool {
        name.range(of: dayFolderPattern, options: .regularExpression) != nil
    }

    public static func parseDayFolder(_ name: String) -> DateComponents? {
        guard isDayFolderName(name), name.count == 8 else { return nil }
        let y = Int(name.prefix(4))
        let m = Int(name.dropFirst(4).prefix(2))
        let d = Int(name.suffix(2))
        guard let y, let m, let d else { return nil }
        return DateComponents(year: y, month: m, day: d)
    }

    public static func shouldDelete(
        folderName: String,
        scope: DbCleanupScope,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let components = parseDayFolder(folderName),
              let folderDate = calendar.date(from: components) else {
            return false
        }

        let startOfToday = calendar.startOfDay(for: now)
        let folderDay = calendar.startOfDay(for: folderDate)

        switch scope {
        case .all:
            return true
        case .today:
            return folderDay == startOfToday
        case .olderThanOneDay:
            // 「一天前」= 今天之前（不含今天）
            return folderDay < startOfToday
        case .olderThanOneWeek:
            guard let threshold = calendar.date(byAdding: .day, value: -7, to: startOfToday) else {
                return false
            }
            return folderDay < threshold
        case .olderThanOneMonth:
            guard let threshold = calendar.date(byAdding: .month, value: -1, to: startOfToday) else {
                return false
            }
            return folderDay < threshold
        }
    }

    public static func plan(
        dbRoot: URL,
        scope: DbCleanupScope,
        fileManager: FileManager = .default,
        now: Date = Date(),
        calendar: Calendar = .current,
        excludingPathPrefix: String? = nil
    ) throws -> DbCleanupPlan {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dbRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return DbCleanupPlan(folders: [], scope: scope)
        }

        let children = try fileManager.contentsOfDirectory(
            at: dbRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var targets: [URL] = []
        for url in children {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let name = url.lastPathComponent
            guard shouldDelete(folderName: name, scope: scope, now: now, calendar: calendar) else { continue }
            if let excludingPathPrefix {
                let normalized = FileIdentity.normalizePath(url.path)
                let exclude = FileIdentity.normalizePath(excludingPathPrefix)
                if normalized == exclude || exclude.hasPrefix(normalized + "/") {
                    continue
                }
            }
            targets.append(url)
        }

        targets.sort { $0.lastPathComponent < $1.lastPathComponent }
        return DbCleanupPlan(folders: targets, scope: scope)
    }

    public static func execute(
        plan: DbCleanupPlan,
        fileManager: FileManager = .default
    ) -> DbCleanupResult {
        var deleted: [URL] = []
        var failed: [DbCleanupFailure] = []
        for folder in plan.folders {
            do {
                try fileManager.removeItem(at: folder)
                deleted.append(folder)
            } catch {
                failed.append(DbCleanupFailure(path: folder.path, message: error.localizedDescription))
            }
        }
        return DbCleanupResult(deleted: deleted, failed: failed)
    }
}
