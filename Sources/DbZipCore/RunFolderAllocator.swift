import Foundation

/// 本地目标目录下按 `01`、`02`… 递增的运行子目录分配规则。
public enum RunFolderAllocator {
    /// - Parameters:
    ///   - existingNames: 目标目录下一层名称
    ///   - isEmpty: 给定名称对应目录是否为空
    /// - Returns: 应使用的文件夹名（至少两位，如 `01`）
    public static func nextFolderName(
        existingNames: [String],
        isEmpty: (String) -> Bool
    ) -> String {
        let numbered: [(name: String, value: Int)] = existingNames.compactMap { name in
            guard name.range(of: #"^\d+$"#, options: .regularExpression) != nil,
                  let value = Int(name) else { return nil }
            return (name, value)
        }
        guard let maxItem = numbered.max(by: { $0.value < $1.value }) else {
            return format(1)
        }
        if isEmpty(maxItem.name) {
            return maxItem.name
        }
        return format(maxItem.value + 1)
    }

    public static func format(_ value: Int) -> String {
        String(format: "%02d", value)
    }
}
