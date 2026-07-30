import AppKit
import DbZipCore
import SwiftUI

struct ExtractHistoryView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("解压历史")
                    .font(.headline)
                Text("\(appModel.extractSessions.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("取消后可继续 · 最多 10 条 · 自动校验目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if appModel.extractSessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("暂无解压历史")
                        .foregroundStyle(.secondary)
                    Text("解压成功后会出现在这里；取消复制也不会丢失。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(appModel.extractSessions) { session in
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                if appModel.openExtractSession(session) {
                                    openWindow(id: "wizard")
                                    WindowFront.scheduleRaise()
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.sourceFileName)
                                        .font(.body.weight(.medium))
                                        .lineLimit(2)
                                    Text(LastSuccessfulAction.abbrevPath(session.extractPath))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(Self.formatTime(session.createdAt))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                NSWorkspace.shared.open(session.extractURL)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("在 Finder 打开")

                            Button(role: .destructive) {
                                appModel.deleteExtractSession(id: session.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("仅删除历史记录，不删磁盘目录")
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear { appModel.refreshExtractSessions() }
        .onReceive(NotificationCenter.default.publisher(for: .openExtractHistoryWindow)) { _ in
            openWindow(id: "extractHistory")
            WindowFront.scheduleRaise()
        }
    }

    private static func formatTime(_ ts: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: ts))
    }
}
