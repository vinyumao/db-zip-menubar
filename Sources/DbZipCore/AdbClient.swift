import Foundation

public struct AdbDevice: Sendable, Hashable, Equatable, Identifiable {
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
    private let processRunner: any ProcessRunning
    private let fileManager: FileManager
    private let configuredPath: String?
    private let pathEnvironment: String?

    public init(
        configuredPath: String? = nil,
        processRunner: any ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.configuredPath = configuredPath
        self.processRunner = processRunner
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

    public func listReadyDevices() throws -> (devices: [AdbDevice], unavailableCount: Int) {
        let adb = try requireAdb()
        let result = try processRunner.run(executable: adb, arguments: ["devices", "-l"])
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
        return (devices, parsed.unavailableCount)
    }

    public func mkdirP(sn: String, remoteDir: String) throws -> Bool {
        let adb = try requireAdb()
        let command = "mkdir -p \"\(remoteDir)\" && echo __MKDIR_OK__"
        let result = try processRunner.run(executable: adb, arguments: ["-s", sn, "shell", command])
        let out = (result.stdout + result.stderr).replacingOccurrences(of: "\r", with: "")
        return out.contains("__MKDIR_OK__")
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
        let adb = try requireAdb()
        let remotePath = "\(remoteDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(localURL.lastPathComponent)"
            .replacingOccurrences(of: "//", with: "/")
        let normalizedRemote: String
        if remoteDir.hasPrefix("/") {
            normalizedRemote = remoteDir.hasSuffix("/")
                ? remoteDir + localURL.lastPathComponent
                : remoteDir + "/" + localURL.lastPathComponent
        } else {
            normalizedRemote = remotePath
        }
        let result = try processRunner.run(
            executable: adb,
            arguments: ["-s", sn, "push", localURL.path, normalizedRemote]
        )
        if result.exitCode != 0 {
            throw AdbError.pushFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func getProp(sn: String, key: String, adb: URL) throws -> String? {
        let result = try processRunner.run(executable: adb, arguments: ["-s", sn, "shell", "getprop", key])
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
