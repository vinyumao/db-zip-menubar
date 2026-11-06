import Foundation

public struct ProcessingPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: DestinationKind
    public var mode: ContentMode
    public var path: String?
    public var device: AdbDevice?
    public var logDays: Int

    public init(id: String = UUID().uuidString, name: String, kind: DestinationKind, mode: ContentMode,
                path: String?, device: AdbDevice?, logDays: Int = 5) {
        self.id = id; self.name = name; self.kind = kind; self.mode = mode
        self.path = path; self.device = device; self.logDays = logDays
    }
}

@MainActor
public final class PresetStore {
    private let url: URL
    public private(set) var presets: [ProcessingPreset]

    public init(appSupportDirectory: URL) {
        url = appSupportDirectory.appendingPathComponent("presets.json")
        presets = (try? JSONDecoder().decode([ProcessingPreset].self, from: Data(contentsOf: url))) ?? []
    }

    public func save(_ preset: ProcessingPreset) throws {
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CopyError.invalidSelection("请输入预设名称") }
        if preset.kind != .device, preset.path?.isEmpty != false { throw CopyError.invalidSelection("预设缺少本地路径") }
        if preset.kind != .path, preset.device == nil { throw CopyError.invalidSelection("预设缺少设备") }
        var updated = presets.filter { $0.id != preset.id && $0.name != name }
        var normalized = preset
        normalized.name = name
        normalized.logDays = min(365, max(1, preset.logDays))
        updated.insert(normalized, at: 0)
        try persist(updated)
    }

    public func remove(id: String) throws { try persist(presets.filter { $0.id != id }) }

    private func persist(_ updated: [ProcessingPreset]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(updated).write(to: url, options: .atomic)
        presets = updated
    }
}
