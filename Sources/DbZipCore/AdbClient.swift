import Foundation

public struct AdbDevice: Sendable, Hashable, Equatable, Identifiable, Codable {
    public var sn: String
    public var brand: String
    public var model: String
    public var state: String

    public var id: String { sn }

    public init(sn: String, brand: String, model: String, state: String = "device") {
        self.sn = sn
        self.brand = brand
        self.model = model
        self.state = state
    }

    public var displayName: String { "\(brand) \(model) (\(sn))" }
}

public enum AdbError: LocalizedError, Sendable {
    case adbNotFound
    case commandFailed(String)
    case mkdirFailed(String)
    case pushFailed(String)

    public var errorDescription: String? {
        switch self {
        case .adbNotFound:
            return "未找到 adb，请在设置中配置或安装 Android platform-tools"
        case .commandFailed(let message):
            return "adb 命令失败: \(message)"
        case .mkdirFailed(let dir):
            return "无法创建设备目录: \(dir)"
        case .pushFailed(let message):
            return "推送失败: \(message)"
        }
    }
}

public struct AdbResolveResult: Sendable, Equatable {
    public var remoteRoot: String
    public var usedFallback: Bool

    public init(remoteRoot: String, usedFallback: Bool) {
        self.remoteRoot = remoteRoot
        self.usedFallback = usedFallback
    }
}

public enum AdbPaths {
    public static let preferredRemoteDir = "/sdcard/Android/data/com.baigong.recopos/files/baigong/recopos"
    public static let fallbackRemoteDir = "/sdcard/db"
}

/// 解析 `adb devices -l` 输出（不含 getprop）。
public enum AdbDevicesParser {
    public struct RawLine: Sendable, Equatable {
        public var sn: String
        public var state: String
        public var product: String?
        public var model: String?

        public init(sn: String, state: String, product: String? = nil, model: String? = nil) {
            self.sn = sn
            self.state = state
            self.product = product
            self.model = model
        }
    }

    public static func parse(_ output: String) -> (ready: [RawLine], unavailableCount: Int) {
        var ready: [RawLine] = []
        var unavailable = 0
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("List") { continue }
            guard let parsed = parseLine(line) else { continue }
            if parsed.state == "device" {
                ready.append(parsed)
            } else {
                unavailable += 1
            }
        }
        return (ready, unavailable)
    }

    public static func parseLine(_ line: String) -> RawLine? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else { return nil }
        let sn = parts[0]
        let state = parts[1]
        var product: String?
        var model: String?
        for part in parts.dropFirst(2) {
            if product == nil, part.hasPrefix("product:") {
                product = String(part.dropFirst("product:".count))
            } else if model == nil, part.hasPrefix("model:") {
                model = String(part.dropFirst("model:".count))
            }
        }
        return RawLine(sn: sn, state: state, product: product, model: model)
    }

    public static func sanitizeProp(_ value: String) -> String? {
        let trimmed = value
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("error:") { return nil }
        if trimmed.contains("not found") { return nil }
        return trimmed
    }
}

public struct AdbClient {
    private let processRunner: (any ProcessRunning)?
    private let control: OperationControl?
    private let fileManager: FileManager
    private let configuredPath: String?
    private let pathEnvironment: String?

    public init(
        configuredPath: String? = nil,
        processRunner: (any ProcessRunning)? = nil,
        control: OperationControl? = nil,
        fileManager: FileManager = .default,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.configuredPath = configuredPath
        self.processRunner = processRunner
        self.control = control
        self.fileManager = fileManager
        self.pathEnvironment = pathEnvironment
    }

    public func resolveAdbURL() -> URL? {
        if let configuredPath, !configuredPath.isEmpty {
            let url = URL(fileURLWithPath: (configuredPath as NSString).standardizingPath)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }

        if let fromPATH = findInPATH("adb") {
            return fromPATH
        }

        let common = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk/platform-tools/adb")
        if fileManager.isExecutableFile(atPath: common.path) {
            return common
        }
        return nil
    }

    public func listReadyDevices() throws -> (devices: [AdbDevice], unavailableCount: Int, unavailableDescriptions: [String]) {
        let adb = try requireAdb()
        let result = try run(executable: adb, arguments: ["devices", "-l"])
        if result.exitCode != 0 {
            throw AdbError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        let parsed = AdbDevicesParser.parse(result.stdout)
        var devices: [AdbDevice] = []
        for line in parsed.ready {
            var brand = try? getProp(sn: line.sn, key: "ro.product.brand", adb: adb)
            if brand == nil {
                brand = try? getProp(sn: line.sn, key: "ro.product.manufacturer", adb: adb)
            }
            if brand == nil {
                brand = line.product
            }
            var model = line.model
            if model == nil {
                model = try? getProp(sn: line.sn, key: "ro.product.model", adb: adb)
            }
            devices.append(
                AdbDevice(
                    sn: line.sn,
                    brand: brand?.isEmpty == false ? brand! : "unknown",
                    model: model?.isEmpty == false ? model! : "unknown"
                )
            )
        }
        let unavailable = result.stdout.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let item = AdbDevicesParser.parseLine(String(line)), item.state != "device",
                  !line.hasPrefix("List"), !line.hasPrefix("*") else { return nil }
            let reason = item.state == "unauthorized" ? "未授权，请在设备上确认 USB 调试" : (item.state == "offline" ? "离线，请重新连接" : item.state)
            return "\(item.sn)：\(reason)"
        }
        return (devices, parsed.unavailableCount, unavailable)
    }

    public func mkdirP(sn: String, remoteDir: String) throws -> Bool {
        let adb = try requireAdb()
        let command = "mkdir -p \(Self.shellQuote(remoteDir)) && echo __MKDIR_OK__"
        let result = try run(executable: adb, arguments: ["-s", sn, "shell", command])
        let out = (result.stdout + result.stderr).replacingOccurrences(of: "\r", with: "")
        return result.exitCode == 0 && out.split(whereSeparator: \.isNewline).contains("__MKDIR_OK__")
    }

    public func resolveDeviceRoot(sn: String) throws -> AdbResolveResult {
        if try mkdirP(sn: sn, remoteDir: AdbPaths.preferredRemoteDir) {
            return AdbResolveResult(remoteRoot: AdbPaths.preferredRemoteDir, usedFallback: false)
        }
        if try mkdirP(sn: sn, remoteDir: AdbPaths.fallbackRemoteDir) {
            return AdbResolveResult(remoteRoot: AdbPaths.fallbackRemoteDir, usedFallback: true)
        }
        throw AdbError.mkdirFailed("首选与回退目录均无法创建")
    }

    public func push(sn: String, localURL: URL, remoteDir: String) throws {
        let entries = try FileManifest.entries(at: localURL)
        try control?.checkCancellation()
        let token = UUID().uuidString
        let stagingRoot = Self.remoteJoin(AdbPaths.fallbackRemoteDir, ".dbzip-" + token)
        let staged = Self.remoteJoin(stagingRoot, localURL.lastPathComponent)
        let destination = Self.remoteJoin(remoteDir, localURL.lastPathComponent)
        let candidate = Self.remoteJoin(remoteDir, ".dbzip-" + token + ".new")
        let backup = Self.remoteJoin(remoteDir, ".dbzip-" + token + ".old")
        let q = Self.shellQuote
        let adb = try requireAdb()
        guard try mkdirP(sn: sn, remoteDir: stagingRoot), try mkdirP(sn: sn, remoteDir: remoteDir) else {
            throw AdbError.mkdirFailed(remoteDir)
        }
        defer {
            _ = try? run(executable: adb, arguments: ["-s", sn, "shell", "rm -rf \(q(stagingRoot)) \(q(candidate))"], critical: true)
        }
        control?.onProgress("推送：\(localURL.lastPathComponent)")
        try pushDirect(sn: sn, localPath: localURL.path, remotePath: staged)
        let directory = try localURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let copy = "cp \(directory ? "-R " : "")\(q(staged)) \(q(candidate)) && chmod \(directory ? "-R ug+rwX" : "660") \(q(candidate)) && echo __PREPARED__"
        try shellChecked(adb: adb, sn: sn, command: copy, sentinel: "__PREPARED__")
        control?.onProgress("校验：\(localURL.lastPathComponent)")
        // Verify in bounded chunks to stay below the adb/shell command length limit.
        var checks: [String] = []
        for entry in entries {
            try control?.checkCancellation()
            let remote = entry.relativePath.isEmpty ? candidate : Self.remoteJoin(candidate, entry.relativePath)
            let digest = try entry.sha256(control: control)
            checks.append("if command -v sha256sum >/dev/null 2>&1; then v=$(sha256sum \(q(remote))) && [ \"${v%% *}\" = \(q(digest)) ] || exit 1; else [ \"$(wc -c < \(q(remote)) | tr -d '[:space:]')\" = '\(entry.bytes)' ] || exit 1; fi")
            if checks.count == 20 {
                try shellChecked(adb: adb, sn: sn, command: checks.joined(separator: "\n") + "\necho __VERIFIED__", sentinel: "__VERIFIED__")
                checks.removeAll()
            }
        }
        if !checks.isEmpty {
            try shellChecked(adb: adb, sn: sn, command: checks.joined(separator: "\n") + "\necho __VERIFIED__", sentinel: "__VERIFIED__")
        }
        try control?.checkCancellation()
        // Only the short rename/rollback phase is non-cancellable. Never remove the
        // previous target until the replacement has been copied and verified.
        let commit = """
        if [ -e \(q(destination)) ] || [ -L \(q(destination)) ]; then mv \(q(destination)) \(q(backup)) || exit 1; fi
        if mv \(q(candidate)) \(q(destination)); then echo __COMMITTED__; else
          if [ -e \(q(backup)) ] || [ -L \(q(backup)) ]; then mv \(q(backup)) \(q(destination)); fi
          exit 1
        fi
        """
        do {
            try shellChecked(adb: adb, sn: sn, command: commit, sentinel: "__COMMITTED__", critical: true)
        } catch {
            let restore = "if [ -e \(q(backup)) ] || [ -L \(q(backup)) ]; then rm -rf \(q(destination)) && mv \(q(backup)) \(q(destination)); fi"
            _ = try? run(executable: adb, arguments: ["-s", sn, "shell", restore], critical: true)
            throw AdbError.pushFailed("\(error.localizedDescription)；如设备已断开，请检查恢复副本：\(backup)")
        }
        _ = try? run(executable: adb, arguments: ["-s", sn, "shell", "rm -rf \(q(backup))"], critical: true)
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shellChecked(adb: URL, sn: String, command: String, sentinel: String, critical: Bool = false) throws {
        let result = try run(executable: adb, arguments: ["-s", sn, "shell", command], critical: critical)
        guard result.exitCode == 0, result.stdout.split(whereSeparator: \.isNewline).contains(Substring(sentinel)) else {
            throw AdbError.pushFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func run(executable: URL, arguments: [String], critical: Bool = false) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let seconds: TimeInterval = critical ? 20 : (arguments.contains("push") ? 300 : 30)
        let runner = processRunner ?? FoundationProcessRunner(timeout: seconds, control: critical ? nil : control)
        return try runner.run(executable: executable, arguments: arguments)
    }

    private func pushDirect(sn: String, localPath: String, remotePath: String) throws {
        let adb = try requireAdb()
        let result = try run(
            executable: adb,
            arguments: ["-s", sn, "push", localPath, remotePath]
        )
        if result.exitCode != 0 {
            throw AdbError.pushFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    public func withControl(_ control: OperationControl) -> AdbClient {
        AdbClient(configuredPath: configuredPath, processRunner: processRunner, control: control,
                  fileManager: fileManager, pathEnvironment: pathEnvironment)
    }

    private static func normalizeRemoteDir(_ dir: String) -> String {
        var value = dir.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private static func remoteJoin(_ dir: String, _ name: String) -> String {
        let root = normalizeRemoteDir(dir)
        if root.hasPrefix("/") {
            return "\(root)/\(name)"
        }
        return "\(root)/\(name)".replacingOccurrences(of: "//", with: "/")
    }

    private func getProp(sn: String, key: String, adb: URL) throws -> String? {
        let result = try run(executable: adb, arguments: ["-s", sn, "shell", "getprop", key])
        return AdbDevicesParser.sanitizeProp(result.stdout)
    }

    private func requireAdb() throws -> URL {
        guard let url = resolveAdbURL() else { throw AdbError.adbNotFound }
        return url
    }

    private func findInPATH(_ name: String) -> URL? {
        let path = pathEnvironment ?? ""
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

public struct DeviceCopyService {
    private let adb: AdbClient
    private let fileManager: FileManager

    public init(adb: AdbClient, fileManager: FileManager = .default) {
        self.adb = adb
        self.fileManager = fileManager
    }

    public func copyCommonFiles(_ files: [URL], sn: String) throws -> AdbResolveResult {
        guard !files.isEmpty else { throw CopyError.noCommonFiles }
        let root = try adb.resolveDeviceRoot(sn: sn)
        for file in files {
            try adb.push(sn: sn, localURL: file, remoteDir: root.remoteRoot)
        }
        return root
    }

    public func copyTreeChildren(from source: URL, sn: String) throws -> AdbResolveResult {
        let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
        guard !children.isEmpty else { throw CopyError.emptySource }
        let root = try adb.resolveDeviceRoot(sn: sn)
        for item in children {
            try adb.push(sn: sn, localURL: item, remoteDir: root.remoteRoot)
        }
        return root
    }
}
