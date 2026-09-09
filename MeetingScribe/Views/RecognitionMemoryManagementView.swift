import SwiftUI

struct RecognitionMemoryManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries = RecognitionMemoryStore.load()
    @State private var workspaceNames: [UUID: String] = [:]
    @State private var error: String?
    @State private var showAdd = false
    @State private var editingEntry: RecognitionMemoryEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("识别记忆").font(.title3.weight(.medium))
                    Text("术语、人名和纠错会自动按项目与使用频率选入转写提示。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("新增纠错…") { showAdd = true }
                Button("完成") { dismiss() }
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
                            Button { editingEntry = entry } label: {
                                Image(systemName: "pencil")
                            }.buttonStyle(.borderless).help("编辑")
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
        .sheet(isPresented: $showAdd) {
            RecognitionMemoryEditView(entry: nil) { entry in
                do {
                    try RecognitionMemoryStore.upsert(entry)
                    entries = RecognitionMemoryStore.load()
                    error = nil
                    showAdd = false
                } catch { self.error = error.localizedDescription }
            } onCancel: {
                showAdd = false
            }
        }
        .sheet(item: $editingEntry) { original in
            RecognitionMemoryEditView(entry: original) { entry in
                do {
                    try RecognitionMemoryStore.update(entry)
                    entries = RecognitionMemoryStore.load()
                    error = nil
                    editingEntry = nil
                } catch { self.error = error.localizedDescription }
            } onCancel: { editingEntry = nil }
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

private struct RecognitionMemoryEditView: View {
    let original: RecognitionMemoryEntry?
    let onSave: (RecognitionMemoryEntry) -> Void
    let onCancel: () -> Void

    @State private var mistaken: String
    @State private var canonical: String
    @State private var kind: RecognitionMemoryEntry.Kind
    @State private var workspaceID: UUID?
    @State private var isEnabled: Bool
    @State private var workspaces: [MeetingWorkspace] = []

    init(entry: RecognitionMemoryEntry?, onSave: @escaping (RecognitionMemoryEntry) -> Void,
         onCancel: @escaping () -> Void) {
        original = entry; self.onSave = onSave; self.onCancel = onCancel
        _mistaken = State(initialValue: entry?.mistaken ?? "")
        _canonical = State(initialValue: entry?.canonical ?? "")
        _kind = State(initialValue: entry?.kind ?? .term)
        _workspaceID = State(initialValue: entry?.workspaceID)
        _isEnabled = State(initialValue: entry?.isEnabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(original == nil ? "新增识别纠错" : "编辑识别记忆")
                .font(.title3.weight(.medium))
            Text("明确的错误写法会在转录后自动替换；正确词也会优先加入后续语音识别提示。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("错误写法（例如：无线AI）", text: $mistaken)
                TextField("正确写法（例如：无相AI）", text: $canonical)
                Picker("类型", selection: $kind) {
                    ForEach(RecognitionMemoryEntry.Kind.allCases) { Text($0.label).tag($0) }
                }
                Picker("适用范围", selection: $workspaceID) {
                    Text("所有会议").tag(UUID?.none)
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(Optional(workspace.id))
                    }
                }
                Toggle("启用", isOn: $isEnabled)
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") {
                    var value = original ?? RecognitionMemoryEntry(
                        canonical: canonical, sourceTitle: "手工录入")
                    value.mistaken = mistaken
                    value.canonical = canonical
                    value.kind = kind
                    value.workspaceID = workspaceID
                    value.isEnabled = isEnabled
                    onSave(value)
                }
                .buttonStyle(.borderedProminent)
                .disabled(canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520, height: 360)
        .onAppear { workspaces = (try? MeetingWorkspaceStore.load()) ?? [] }
    }
}
