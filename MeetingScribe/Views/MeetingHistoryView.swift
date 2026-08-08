import SwiftUI

struct MeetingHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let onReprocess: (MeetingRecord) -> Void
    let onAnalyzeTranscript: (MeetingRecord, Transcript) -> Void

    @State private var records: [MeetingRecord] = []
    @State private var selection: UUID?
    @State private var query = ""
    @State private var error: String?
    @State private var pendingDelete: MeetingRecord?
    @State private var exportMessage: String?
    @State private var workspaces: [MeetingWorkspace] = []
    @State private var scope: MeetingLibraryScope = .recent
    @AppStorage("meetingLibrary.scope") private var storedScope = "recent"
    @AppStorage("meetingLibrary.sort") private var storedSort = MeetingLibrarySort.newest.rawValue
    @AppStorage("meetingLibrary.workspacesExpanded") private var workspacesExpanded = true
    @AppStorage("meetingLibrary.tagsExpanded") private var tagsExpanded = true
    @State private var showWorkspaceManager = false
    @State private var editingClassification: MeetingRecord?
    @State private var dashboardWorkspace: MeetingWorkspace?
    @State private var editingTranscript: MeetingRecord?
    @State private var translatingTranscript: MeetingRecord?
    @State private var emailRecord: MeetingRecord?
    @State private var detailTab: DetailTab = .minutes

    private enum DetailTab: String, CaseIterable {
        case minutes = "纪要", actions = "待办", transcript = "逐字稿", email = "邮件", info = "信息"
    }

    private var filtered: [MeetingRecord] {
        let scoped = MeetingLibrary.filter(records, scope: scope)
        return scoped.filter { record in
            MeetingSearch.matches(record, workspaceName: workspace(for: record)?.name,
                                  query: query)
        }
    }

    private var selected: MeetingRecord? {
        records.first { $0.id == selection }
    }

    private var sort: MeetingLibrarySort {
        get { MeetingLibrarySort(rawValue: storedSort) ?? .newest }
        nonmutating set { storedSort = newValue.rawValue }
    }

    private var availableTags: [(name: String, count: Int)] {
        var values: [String: (name: String, count: Int)] = [:]
        for record in records where record.isArchived != true {
            for tag in record.tags ?? [] {
                let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .lowercased()
                let current = values[key]
                values[key] = (current?.name ?? name, (current?.count ?? 0) + 1)
            }
        }
        return values.values.sorted {
            $0.count == $1.count
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.count > $1.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                librarySidebar
                    .frame(minWidth: 180, idealWidth: 205, maxWidth: 240)
                meetingList
                    .frame(minWidth: 270, idealWidth: 310, maxWidth: 370)

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
        .frame(width: 1160, height: 700)
        .searchable(text: $query, prompt: "组合搜索：空间 标签 标题 纪要 说话人")
        .onAppear(perform: load)
        .onChange(of: scope) { _, value in storedScope = serializedScope(value) }
        .sheet(isPresented: $showWorkspaceManager, onDismiss: loadWorkspaces) {
            WorkspaceManagementView()
        }
        .sheet(item: $editingClassification) { record in
            MeetingClassificationView(record: record, workspaces: workspaces,
                                      tagSuggestions: MeetingTags.suggestions(from: records)) { updated in
                if let index = records.firstIndex(where: { $0.id == updated.id }) {
                    records[index] = updated
                }
                editingClassification = nil
            } onCancel: { editingClassification = nil }
        }
        .sheet(item: $dashboardWorkspace) { workspace in
            WorkspaceDashboardView(
                workspace: workspace,
                records: records.filter { $0.workspaceID == workspace.id })
        }
        .sheet(item: $editingTranscript) { record in
            TranscriptEditorView(record: record) { transcript in
                editingTranscript = nil
                onAnalyzeTranscript(record, transcript)
            }
        }
        .sheet(item: $translatingTranscript) { record in
            TranscriptTranslationView(record: record) { updated in
                if let index = records.firstIndex(where: { $0.id == updated.id }) {
                    records[index] = updated
                }
            }
        }
        .sheet(item: $emailRecord) { record in
            MeetingEmailView(
                meetingID: record.id, title: record.title,
                workspaceName: workspace(for: record)?.name,
                minutesTemplateID: record.minutesTemplateID,
                workspaceEmailTemplateID: workspace(for: record)?.defaultEmailTemplateID,
                minutes: record.summaryMarkdown, initialDrafts: record.emailDrafts
            ) { drafts in
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    records[index].emailDrafts = drafts
                }
            }
        }
        .onChange(of: filtered.map(\.id)) { _, ids in
            if selection == nil || !ids.contains(selection!) { selection = ids.first }
        }
        .onChange(of: selection) { _, _ in detailTab = .minutes }
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

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会议资料库").font(.headline)
                Spacer()
                Button { showWorkspaceManager = true } label: {
                    Image(systemName: "folder.badge.gearshape")
                }.buttonStyle(.borderless).help("管理会议空间")
            }.padding(12)
            Divider()
            List {
                Section("智能分类") {
                    scopeRow("最近会议", icon: "clock", count: MeetingLibrary.filter(records, scope: .recent).count, scope: .recent)
                    scopeRow("全部会议", icon: "tray.full", count: MeetingLibrary.filter(records, scope: .all).count, scope: .all)
                    scopeRow("待办未完成", icon: "checklist", count: MeetingLibrary.filter(records, scope: .pendingActions).count, scope: .pendingActions)
                    scopeRow("未归组", icon: "questionmark.folder", count: MeetingLibrary.filter(records, scope: .ungrouped).count, scope: .ungrouped)
                }
                Section {
                    DisclosureGroup(isExpanded: $workspacesExpanded) {
                        ForEach(MeetingWorkspace.Kind.allCases) { kind in
                            let values = workspaces.filter { $0.kind == kind }
                            if !values.isEmpty {
                                Text(kind.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(values) { workspace in
                                    scopeRow(workspace.name,
                                             icon: kind == .recurring ? "repeat" : "folder",
                                             count: MeetingLibrary.filter(records, scope: .workspace(workspace.id)).count,
                                             scope: .workspace(workspace.id))
                                        .contextMenu {
                                            Button("查看空间总览") { dashboardWorkspace = workspace }
                                        }
                                }
                            }
                        }
                    } label: {
                        Label("会议空间", systemImage: "folder")
                    }
                }
                if !availableTags.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $tagsExpanded) {
                            ForEach(availableTags, id: \.name) { tag in
                                scopeRow(tag.name, icon: "tag", count: tag.count,
                                         scope: .meetingTag(tag.name))
                            }
                        } label: {
                            Label("会议标签", systemImage: "tag")
                        }
                    }
                }
            }.listStyle(.sidebar)
        }
    }

    private func scopeRow(_ title: String, icon: String, count: Int,
                          scope: MeetingLibraryScope) -> some View {
        Button {
            self.scope = scope
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(self.scope == scope ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private var meetingList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(scopeTitle).font(.headline)
                Spacer()
                Menu {
                    Button {
                        scope = scope == .favorites ? .all : .favorites
                    } label: {
                        Label("已收藏（\(MeetingLibrary.filter(records, scope: .favorites).count)）",
                              systemImage: scope == .favorites ? "checkmark" : "star")
                    }
                    Button {
                        scope = scope == .archived ? .all : .archived
                    } label: {
                        Label("已归档（\(MeetingLibrary.filter(records, scope: .archived).count)）",
                              systemImage: scope == .archived ? "checkmark" : "archivebox")
                    }
                    if scope == .favorites || scope == .archived {
                        Divider()
                        Button("清除状态筛选") { scope = .all }
                    }
                } label: {
                    Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Menu {
                    Picker("排序", selection: Binding(get: { sort }, set: { sort = $0 })) {
                        ForEach(MeetingLibrarySort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Label(sort.label, systemImage: "arrow.up.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if let workspace = selectedFilterWorkspace {
                    Button { dashboardWorkspace = workspace } label: {
                        Image(systemName: "chart.bar.doc.horizontal")
                    }.buttonStyle(.borderless).help("空间总览与待办台账")
                }
            }.padding(12)
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "没有会议" : "没有搜索结果",
                                       systemImage: "doc.text.magnifyingglass")
            } else {
                List(selection: $selection) {
                    ForEach(listSections) { section in
                        Section(section.title) {
                            ForEach(section.records) { meetingRow($0).tag($0.id) }
                        }
                    }
                }
            }
        }
    }

    private func meetingRow(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if record.isFavorite == true { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                Text(record.title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if record.emailDrafts != nil { Image(systemName: "envelope.fill").foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text(TranscriptSegment.humanDuration(record.duration))
                if let workspace = workspace(for: record) {
                    Label(workspace.name, systemImage: workspace.kind == .recurring ? "repeat" : "folder")
                }
            }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 8) {
                if let tags = record.tags, !tags.isEmpty {
                    Text(tags.prefix(2).map { "#\($0)" }.joined(separator: "  "))
                        .foregroundStyle(Color.accentColor)
                    if tags.count > 2 {
                        Text("+\(tags.count - 2)").foregroundStyle(.secondary)
                    }
                }
                if record.openActionCount > 0 {
                    Label("\(record.openActionCount) 待办", systemImage: "checklist")
                        .foregroundStyle(.orange)
                }
            }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.vertical, 4)
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
                Button { toggleFavorite(record) } label: {
                    Image(systemName: record.isFavorite == true ? "star.fill" : "star")
                }.help(record.isFavorite == true ? "取消收藏" : "收藏")
                if FileManager.default.fileExists(atPath: record.sourcePath) {
                    Button("打开源文件") { NSWorkspace.shared.open(record.sourceURL) }
                    Button("重新处理") { onReprocess(record) }
                } else {
                    Label("源文件已移动", systemImage: "questionmark.folder")
                        .font(.caption).foregroundStyle(.orange)
                }
                Menu("更多操作") {
                    Button("会议信息、归组与标签…") { editingClassification = record }
                    Button("生成同步邮件…") { emailRecord = record }
                    Button(record.isArchived == true ? "移出归档" : "归档") {
                        toggleArchived(record)
                    }
                    Divider()
                    Button("校正逐字稿并重新生成…") { editingTranscript = record }
                    Button("生成双栏释义…") { translatingTranscript = record }
                    Divider()
                    Button("导出…") { export(record) }
                }
                Button(role: .destructive) { pendingDelete = record } label: {
                    Image(systemName: "trash")
                }
            }
            .padding(14)
            Divider()
            Picker("", selection: $detailTab) {
                ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            detailContent(record)
        }
        .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func detailContent(_ record: MeetingRecord) -> some View {
        switch detailTab {
        case .minutes:
            MarkdownView(markdown: record.summaryMarkdown)
        case .actions:
            if let actions = record.structuredSummary?.actionItems, !actions.isEmpty {
                List(actions.indices, id: \.self) { index in
                    let action = actions[index]
                    VStack(alignment: .leading, spacing: 5) {
                        Text(action.task).font(.body.weight(.medium))
                        HStack {
                            Label(action.owner.isEmpty ? "待确认" : action.owner, systemImage: "person")
                            Label(action.due.isEmpty ? "待确认" : action.due, systemImage: "calendar")
                            Text(action.status.isEmpty ? "状态待确认" : action.status)
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            } else {
                ContentUnavailableView("没有结构化待办", systemImage: "checklist")
            }
        case .transcript:
            ScrollView {
                Text(record.transcript.timecodedText)
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        case .email:
            if let drafts = record.emailDrafts, !drafts.chinese.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("中文草稿").font(.headline)
                        Text(drafts.chinese).textSelection(.enabled)
                        if !drafts.hongKongTraditional.isEmpty {
                            Divider(); Text("香港繁体草稿").font(.headline)
                            Text(drafts.hongKongTraditional).textSelection(.enabled)
                        }
                        Button("打开邮件编辑器…") { emailRecord = record }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                }
            } else {
                VStack(spacing: 12) {
                    ContentUnavailableView("尚未生成同步邮件", systemImage: "envelope",
                                           description: Text("可以从本次纪要生成中文和香港繁体草稿。"))
                    Button("生成同步邮件…") { emailRecord = record }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .info:
            Form {
                LabeledContent("会议名称", value: record.title)
                LabeledContent("时间", value: record.createdAt.formatted())
                LabeledContent("时长", value: TranscriptSegment.humanDuration(record.duration))
                LabeledContent("空间", value: workspace(for: record)?.name ?? "未归组")
                LabeledContent("纪要模板", value: MinutesTemplate.template(id: record.minutesTemplateID).name)
                LabeledContent("模型", value: "\(record.backend) · \(record.model)")
                LabeledContent("源文件", value: record.sourcePath)
                if let materials = record.materials, !materials.isEmpty {
                    LabeledContent("会前材料", value: materials.map(\.name).joined(separator: "、"))
                }
            }.formStyle(.grouped)
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: return "全部会议"
        case .recent: return "最近会议"
        case .pendingActions: return "待办未完成"
        case .favorites: return "已收藏"
        case .ungrouped: return "未归组"
        case .archived: return "已归档"
        case .workspace(let id): return workspaces.first { $0.id == id }?.name ?? "会议空间"
        case .meetingTag(let tag): return "标签 · \(tag)"
        }
    }

    private var listSections: [MeetingLibrarySection] {
        MeetingLibrary.timeSections(filtered, sort: sort)
    }

    private func load() {
        do {
            records = try MeetingHistoryStore.loadAll()
            loadWorkspaces()
            scope = restoredScope(storedScope)
            selection = listSections.first?.records.first?.id
            error = nil
        } catch {
            self.error = "读取历史失败：\(error.localizedDescription)"
        }
    }

    private func serializedScope(_ value: MeetingLibraryScope) -> String {
        switch value {
        case .all: return "all"
        case .recent: return "recent"
        case .pendingActions: return "pendingActions"
        case .favorites: return "favorites"
        case .ungrouped: return "ungrouped"
        case .archived: return "archived"
        case .workspace(let id): return "workspace:\(id.uuidString)"
        case .meetingTag(let tag): return "tag:\(tag)"
        }
    }

    private func restoredScope(_ value: String) -> MeetingLibraryScope {
        switch value {
        case "all": return .all
        case "pendingActions": return .pendingActions
        case "favorites": return .favorites
        case "ungrouped": return .ungrouped
        case "archived": return .archived
        default:
            if value.hasPrefix("workspace:"),
               let id = UUID(uuidString: String(value.dropFirst("workspace:".count))),
               workspaces.contains(where: { $0.id == id }) {
                return .workspace(id)
            }
            if value.hasPrefix("tag:") {
                let tag = String(value.dropFirst("tag:".count))
                if availableTags.contains(where: {
                    $0.name.localizedCaseInsensitiveCompare(tag) == .orderedSame
                }) {
                    return .meetingTag(tag)
                }
            }
            return .recent
        }
    }

    private func loadWorkspaces() {
        workspaces = (try? MeetingWorkspaceStore.load()) ?? []
    }

    private func workspace(for record: MeetingRecord) -> MeetingWorkspace? {
        workspaces.first { $0.id == record.workspaceID }
    }

    private var selectedFilterWorkspace: MeetingWorkspace? {
        guard case .workspace(let id) = scope else { return nil }
        return workspaces.first { $0.id == id }
    }

    private func toggleFavorite(_ record: MeetingRecord) {
        updateLibraryState(record, favorite: !(record.isFavorite ?? false), archived: nil)
    }

    private func toggleArchived(_ record: MeetingRecord) {
        updateLibraryState(record, favorite: nil, archived: !(record.isArchived ?? false))
    }

    private func updateLibraryState(_ record: MeetingRecord, favorite: Bool?, archived: Bool?) {
        do {
            let updated = try MeetingHistoryStore.updateLibraryState(
                id: record.id, favorite: favorite, archived: archived)
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = updated }
            error = nil
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
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
