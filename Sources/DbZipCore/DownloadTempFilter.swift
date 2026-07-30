import Foundation

/// 过滤浏览器下载临时名，避免未完成文件入队。
public enum DownloadTempFilter {
    private static let temporaryExtensions: Set<String> = [
        "crdownload",
        "download",
        "part",
        "partial",
        "tmp",
        "temp",
        "aria2",
        "!ut",
        "bc!",
        "opdownload"
    ]

    public static func isTemporaryName(_ fileName: String) -> Bool {
        if fileName.hasPrefix(".") { return true }
        if fileName.hasSuffix("~") { return true }

        let lower = fileName.lowercased()
        if lower.hasSuffix(".crdownload") { return true }
        if lower.hasSuffix(".download") { return true }

        guard let ext = extensionOf(lower) else { return false }
        return temporaryExtensions.contains(ext)
    }

    public static func isCandidateZipName(_ fileName: String) -> Bool {
        !isTemporaryName(fileName) && fileName.lowercased().hasSuffix(".zip")
    }

    private static func extensionOf(_ lowercasedName: String) -> String? {
        guard let dot = lowercasedName.lastIndex(of: ".") else { return nil }
        let ext = String(lowercasedName[lowercasedName.index(after: dot)...])
        return ext.isEmpty ? nil : ext
    }
}
