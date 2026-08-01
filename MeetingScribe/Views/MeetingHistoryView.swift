import SwiftUI

struct MeetingHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let onReprocess: (MeetingRecord) -> Void

    @State private var records: [MeetingRecord] = []
    @State private var selection: UUID?
    @State private var query = ""
    @State private var error: String?
    @State private var pendingDelete: MeetingRecord?
    @State private var exportMessage: String?
    @State private var workspaces: [MeetingWorkspace] = []
    @State private var workspaceFilter: WorkspaceFilter = .all
    @State private var showWorkspaceManager = false
    @State private var editingClassification: MeetingRecord?

    private enum WorkspaceFilter: Hashable { case all, ungrouped, workspace(UUID) }

    private var filtered: [MeetingRecord] {
        let scoped = records.filter { record in
            switch workspaceFilter {
            case .all: return true
            case .ungrouped: return record.workspaceID == nil
            case .workspace(let id): return record.workspaceID == id
            }
        }
        guard !query.isEmpty else { return scoped }
        return scoped.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.summaryMarkdown.localizedCaseInsensitiveContains(query)
                || $0.speakerNames.values.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var selected: MeetingRecord? {
        records.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Picker("", selection: $workspaceFilter) {
                            Text("全部空间").tag(WorkspaceFilter.all)
                            Text("未归组").tag(WorkspaceFilter.ungrouped)
                            ForEach(workspaces) { workspace in
                                Text(workspace.name).tag(WorkspaceFilter.workspace(workspace.id))
                            }
                        }.labelsHidden()
                        Button { showWorkspaceManager = true } label: {
                            Image(systemName: "folder.badge.gearshape")
                        }.help("管理会议空间")
                    }.padding(8)
                    Divider()
                    if filtered.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? "还没有历史会议" : "没有搜索结果",
                            systemImage: "clock",
                            description: Text(query.isEmpty
                                              ? "成功生成纪要后会自动出现在这里。"
                                              : "请尝试其他关键词。"))
                    } else {
                        List(filtered, selection: $selection) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(record.backend) · \(record.model)")
                                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                if let workspace = workspace(for: record) {
                                    Label(workspace.name, systemImage: "folder")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if let tags = record.tags, !tags.isEmpty {
                                    Text(tags.map { "#\($0)" }.joined(separator: "  "))
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(record.id)
                        }
                    }
                }
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)

                if let record = selected {
                    historyDetail(record)
                } else {
                    ContentUnavailableView("选择一场会议", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()
            HStack {
                if let message = error ?? exportMessage {
                    Text(message).font(.caption)
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 920, height: 620)
        .searchable(text: $query, prompt: "搜索标题、纪要或说话人")
        .onAppear(perform: load)
        .sheet(isPresented: $showWorkspaceManager, onDismiss: loadWorkspaces) {
            WorkspaceManagementView()
        }
        .sheet(item: $editingClassification) { record in
            MeetingClassificationView(record: record, workspaces: workspaces) { updated in
                if let index = records.firstIndex(where: { $0.id == updated.id }) {
                    records[index] = updated
                }
                editingClassification = nil
            } onCancel: { editingClassification = nil }
        }
        .onChange(of: filtered.map(\.id)) { _, ids in
            if selection == nil || !ids.contains(selection!) { selection = ids.first }
        }
        .alert("删除这条历史记录？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) { removePending() }
        } message: {
            Text("只删除 MeetingScribe 的历史副本，不会删除原始媒体或已经导出的文件。")
        }
    }

    @ViewBuilder
    private func historyDetail(_ record: MeetingRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(.headline)
                    Text("\(TranscriptSegment.humanDuration(record.duration)) · \(record.createdAt.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                    if let tags = record.tags, !tags.isEmpty {
                        Text(tags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Spacer()
                if FileManager.default.fileExists(atPath: record.sourcePath) {
                    Button("打开源文件") { NSWorkspace.shared.open(record.sourceURL) }
                    Button("重新处理") { onReprocess(record) }
                } else {
                    Label("源文件已移动", systemImage: "questionmark.folder")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("归组与标签…") { editingClassification = record }
                Button("导出…") { export(record) }
                Button(role: .destructive) { pendingDelete = record } label: {
                    Image(systemName: "trash")
                }
            }
            .padding(14)
            Divider()
            MarkdownView(markdown: record.summaryMarkdown)
        }
        .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        do {
            records = try MeetingHistoryStore.loadAll()
            loadWorkspaces()
            selection = records.first?.id
            error = nil
        } catch {
            self.error = "读取历史失败：\(error.localizedDescription)"
        }
    }

    private func loadWorkspaces() {
        workspaces = (try? MeetingWorkspaceStore.load()) ?? []
    }

    private func workspace(for record: MeetingRecord) -> MeetingWorkspace? {
        workspaces.first { $0.id == record.workspaceID }
    }

    private func removePending() {
        guard let record = pendingDelete else { return }
        pendingDelete = nil
        do {
            try MeetingHistoryStore.remove(id: record.id)
            records.removeAll { $0.id == record.id }
            selection = records.first?.id
            error = nil
        } catch {
            self.error = "删除失败：\(error.localizedDescription)"
        }
    }

    private func export(_ record: MeetingRecord) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            try MeetingHistoryStore.export(record, to: directory)
            exportMessage = "已导出到 \(directory.path)"
            error = nil
        } catch {
            self.error = "导出失败：\(error.localizedDescription)"
        }
    }
}
