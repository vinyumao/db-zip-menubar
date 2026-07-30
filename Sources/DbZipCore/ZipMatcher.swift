import Foundation

/// 对齐旧脚本 `is_target_zip`；`.zip` 后缀大小写不敏感。
public enum ZipMatcher {
    public static func isTargetZip(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        guard lower.hasSuffix(".zip") else { return false }

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
