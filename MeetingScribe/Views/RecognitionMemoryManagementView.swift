import SwiftUI

struct RecognitionMemoryManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries = RecognitionMemoryStore.load()
    @State private var workspaceNames: [UUID: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("识别记忆").font(.title3.weight(.medium))
                    Text("术语、人名和纠错会自动按项目与使用频率选入转写提示。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Button("完成") { dismiss() }
            }.padding(18)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("还没有识别记忆", systemImage: "text.badge.checkmark",
                                       description: Text("在会议结果页点击“纠正并学习”，或登记说话人姓名。"))
            } else {
                List {
                    ForEach($entries) { $entry in
                        HStack(spacing: 12) {
                            Toggle("", isOn: $entry.isEnabled).labelsHidden()
                                .onChange(of: entry.isEnabled) { _, _ in persist() }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.mistaken.isEmpty ? entry.canonical : "\(entry.mistaken) → \(entry.canonical)")
                                Text("\(entry.kind.label) · \(scopeLabel(for: entry)) · 识别提示 \(entry.promptUsageCount ?? 0) 次 · 自动纠正 \(entry.usageCount) 次")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { remove(entry.id) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }
        .frame(width: 720, height: 520)
        .onAppear {
            workspaceNames = Dictionary(uniqueKeysWithValues:
                ((try? MeetingWorkspaceStore.load()) ?? []).map { ($0.id, $0.name) })
        }
    }

    private func persist() {
        do { try RecognitionMemoryStore.save(entries) }
        catch { self.error = error.localizedDescription }
    }

    private func remove(_ id: UUID) {
        do { try RecognitionMemoryStore.remove(id: id); entries.removeAll { $0.id == id } }
        catch { self.error = error.localizedDescription }
    }

    private func scopeLabel(for entry: RecognitionMemoryEntry) -> String {
        guard let id = entry.workspaceID else { return "所有会议" }
        return workspaceNames[id].map { "项目：\($0)" } ?? "原项目已删除"
    }
}
