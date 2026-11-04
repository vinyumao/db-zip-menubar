import Foundation

/// 支持旧脚本 `is_target_zip` 的业务包和 upload_log 日志包；`.zip` 后缀大小写不敏感。
public enum ZipMatcher {
    private static let uploadLogPattern = #"^upload_log_[^_]+_[^_]+_[^_]+_[0-9]{10,}\.zip$"#

    public static func isTargetZip(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        guard lower.hasSuffix(".zip") else { return false }

        if lower.range(of: uploadLogPattern, options: .regularExpression) != nil {
            return true
        }

        let underscoreCount = fileName.filter { $0 == "_" }.count
        guard underscoreCount >= 2 else { return false }

        guard fileName.range(of: #"(^|_)[0-9]{9}_"#, options: .regularExpression) != nil else {
            return false
        }

        guard lower.range(of: #"_[0-9]{10,}\.zip$"#, options: .regularExpression) != nil else {
            return false
        }

        return true
    }

    public static func mismatchReason(for fileName: String) -> String? {
        if isTargetZip(fileName) { return nil }

        let lower = fileName.lowercased()
        if !lower.hasSuffix(".zip") {
            return "文件名不以 .zip 结尾"
        }
        if lower.hasPrefix("upload_log_") {
            return "日志文件名应为 upload_log_<字段1>_<字段2>_<设备号>_<时间戳（至少 10 位数字）>.zip"
        }
        if fileName.filter({ $0 == "_" }).count < 2 {
            return "下划线数量不足 2 个"
        }
        if fileName.range(of: #"(^|_)[0-9]{9}_"#, options: .regularExpression) == nil {
            return "缺少 9 位数字段（业务号）"
        }
        if lower.range(of: #"_[0-9]{10,}\.zip$"#, options: .regularExpression) == nil {
            return "缺少末尾时间戳段"
        }
        return "不符合目标 zip 规则"
    }
}
