import SwiftUI
import DbZipCore

struct ContentPreviewStepView: View {
    @ObservedObject var coordinator: WizardCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if coordinator.contentMode == .common {
                HStack {
                    Text("最近日志天数")
                    TextField("天数", value: $coordinator.logDays, format: .number)
                        .frame(width: 60)
                    Button("重新筛选") {
                        coordinator.logDays = min(365, max(1, coordinator.logDays))
                        Task { await coordinator.chooseContentMode(.common) }
                    }
                    .disabled(coordinator.previewLoading)
                }
            }
            if coordinator.previewLoading { ProgressView("读取文件清单…") }
            if let plan = coordinator.contentPlan {
                ForEach(plan.warnings, id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("已选 \(coordinator.selectedItemIDs.count)/\(plan.items.count) 项 · \(formattedBytes(plan.items.filter { coordinator.selectedItemIDs.contains($0.id) }.reduce(0) { $0 + $1.bytes }))")
                        .font(.callout)
                    Spacer()
                    Button("全选") { coordinator.selectedItemIDs = Set(plan.items.map(\.id)) }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(plan.items) { item in
                            Toggle(isOn: Binding(
                                get: { coordinator.selectedItemIDs.contains(item.id) },
                                set: { if $0 { coordinator.selectedItemIDs.insert(item.id) } else { coordinator.selectedItemIDs.remove(item.id) } }
                            )) {
                                HStack {
                                    Image(systemName: item.isDirectory ? "folder" : "doc")
                                    Text(item.url.lastPathComponent).lineLimit(2).help(item.url.path)
                                    Spacer()
                                    Text(formattedBytes(item.bytes)).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(8)
                }
                .frame(height: min(280, max(80, CGFloat(plan.items.count) * 32)))
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = coordinator.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
            PresetSaveRow(coordinator: coordinator)
            HStack {
                Button("返回") { coordinator.goBack() }
                Spacer()
                Button("确认并复制") { Task { await coordinator.confirmPreview() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(coordinator.previewLoading || coordinator.selectedItemIDs.isEmpty || coordinator.contentPlan == nil)
            }
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct PresetSaveRow: View {
    @ObservedObject var coordinator: WizardCoordinator
    @EnvironmentObject private var appModel: AppModel
    @State private var name = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("预设名称（可选）", text: $name)
                Button("保存预设") {
                    do {
                        try appModel.savePreset(name: name, coordinator: coordinator)
                        message = "已保存目标、内容模式和日志天数；每次仍会预览确认。"
                    } catch { message = error.localizedDescription }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
