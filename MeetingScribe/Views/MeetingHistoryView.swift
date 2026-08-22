import SwiftUI

struct MeetingHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let onReprocess: (MeetingRecord) -> Void
    let onAnalyzeTranscript: (MeetingRecord, Transcript) -> Void

    @State private var records: [MeetingRecord] = []
    @State private var loadIssues: [MeetingHistoryStore.LoadIssue] = []
    @State private var selection: UUID?
    @State private var query = ""
    @State private var error: String?
    @State private var pendingDelete: MeetingRecord?
    @State private var exportMessage: String?
    @State private var workspaces: [MeetingWorkspace] = []
    @State private var scope: MeetingLibraryScope = .recent
    @AppStorage("meetingLibrary.scope") private var storedScope = "recent"
    @AppStorage("meetingLibrary.sort") private var storedSort = MeetingLibrarySort.newest.rawValue
    @State private var showWorkspaceManager = false
    @State private var editingClassification: MeetingRecord?
    @State private var dashboardWorkspace: MeetingWorkspace?
    @State private var editingTranscript: MeetingRecord?
    @State private var learningRecognition: MeetingRecord?
    @State private var translatingTranscript: MeetingRecord?
    @State private var emailRecord: MeetingRecord?
    @State private var editingAction: ActionEditTarget?
    @State private var pendingActionReviewWorkspace: MeetingWorkspace?
    @State private var isReviewingActions = false
    @State private var detailTab: DetailTab = .minutes
    @State private var meetingTypeFilter = ""
    @State private var customerFilter = ""
    @State private var projectFilter = ""
    @State private var showLoadIssues = false
    @State private var pendingVersionCleanup: MeetingRecord?

    init(initialSelection: UUID? = nil,
         onReprocess: @escaping (MeetingRecord) -> Void,
         onAnalyzeTranscript: @escaping (MeetingRecord, Transcript) -> Void) {
        self.onReprocess = onReprocess
        self.onAnalyzeTranscript = onAnalyzeTranscript
        _selection = State(initialValue: initialSelection)
    }

    private enum DetailTab: String, CaseIterable {
        case minutes = "纪要", actions = "待办", email = "邮件", info = "信息"
    }

    private struct ActionEditTarget: Identifiable {
        let id = UUID()
        let meetingID: UUID
        let index: Int
        let action: StructuredMinutes.ActionItem
    }

    private var filtered: [MeetingRecord] {
        let scoped: [MeetingRecord]
        if case .customer(let customerID) = scope {
            let projectIDs = Set(workspaces.filter { $0.customerID == customerID }.map(\.id))
            scoped = records.filter {
                $0.isArchived != true
                    && ($0.workspaceID == customerID || $0.workspaceID.map(projectIDs.contains) == true)
            }
        } else {
            scoped = MeetingLibrary.filter(records, scope: scope)
        }
        return scoped.filter { record in
            let matchesType = meetingTypeFilter.isEmpty || (record.tags ?? []).contains {
                $0.localizedCaseInsensitiveCompare(meetingTypeFilter) == .orderedSame
            }
            let matchesCustomer = customerFilter.isEmpty
                || classification(record.customerName) == customerFilter
            let matchesProject = projectFilter.isEmpty
                || classification(record.projectName) == projectFilter
            return MeetingSearch.matches(record, workspaceName: workspace(for: record)?.name,
                                         query: query) && matchesType && matchesCustomer && matchesProject
        }
    }

    /// One visible row per source recording. If the user selects an older
    /// version from the version menu, that version temporarily represents its
    /// group without expanding the whole list.
    private var displayedRecords: [MeetingRecord] {
        let groups = Dictionary(grouping: filtered, by: versionKey)
        return groups.values.compactMap { versions in
            if let selected, versions.contains(where: { $0.id == selected.id }) { return selected }
            return versions.max { $0.createdAt < $1.createdAt }
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

    private var classificationCustomers: [String] {
        Set(classificationRecords.map { classification($0.customerName) })
            .sorted { lhs, rhs in
                lhs == "未知" || (rhs != "未知" && lhs.localizedStandardCompare(rhs) == .orderedAscending)
            }
    }

    private func classificationProjects(customer: String) -> [String] {
        Set(classificationRecords.filter {
            classification($0.customerName) == customer
        }.map { classification($0.projectName) }).sorted { lhs, rhs in
            lhs == "未知" || (rhs != "未知" && lhs.localizedStandardCompare(rhs) == .orderedAscending)
        }
    }

    private func classificationTypes(customer: String, project: String) -> [String] {
        Set(classificationRecords.filter {
            classification($0.customerName) == customer
                && classification($0.projectName) == project
        }.flatMap { $0.tags ?? [] }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var classificationRecords: [MeetingRecord] {
        Dictionary(grouping: records.filter { $0.isArchived != true }, by: versionKey)
            .values.compactMap { $0.max { $0.createdAt < $1.createdAt } }
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
        .searchable(text: $query, prompt: "组合搜索：项目 标签 标题 纪要 说话人")
        .onAppear(perform: load)
        .onChange(of: scope) { _, value in storedScope = serializedScope(value) }
        .sheet(isPresented: $showWorkspaceManager, onDismiss: loadWorkspaces) {
            WorkspaceManagementView()
        }
        .sheet(item: $editingClassification) { record in
            MeetingClassificationView(record: record, workspaces: workspaces, records: records,
                                      tagSuggestions: MeetingTags.suggestions(from: records)) { updated in
                selection = updated.id
                load()
                editingClassification = nil
            } onCancel: { editingClassification = nil }
        }
        .sheet(item: $dashboardWorkspace) { workspace in
            WorkspaceDashboardView(
                workspace: workspace,
                records: records.filter { $0.workspaceID == workspace.id },
                onReviewHistory: {
                    dashboardWorkspace = nil
                    pendingActionReviewWorkspace = workspace
                },
                onOpenMeeting: { id in
                    dashboardWorkspace = nil
                    selection = id
                })
        }
        .sheet(item: $editingTranscript) { record in
            TranscriptEditorView(record: record) { transcript in
                editingTranscript = nil
                onAnalyzeTranscript(record, transcript)
            }
        }
        .sheet(item: $learningRecognition) { record in
            RecognitionLearningView(
                workspaceID: record.workspaceID,
                sourceTitle: record.title,
                uncertainties: record.structuredSummary?.uncertainties ?? []) {
                    let corrected = RecognitionMemoryStore.apply(
                        to: record.transcript, workspaceID: record.workspaceID)
                    learningRecognition = nil
                    onAnalyzeTranscript(record, corrected)
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
                workspaceName: record.projectName,
                minutesTemplateID: record.minutesTemplateID,
                workspaceEmailTemplateID: workspace(for: record)?.defaultEmailTemplateID,
                minutes: StructuredMinutesRenderer.markdown(for: record),
                initialDrafts: record.emailDrafts
            ) { drafts in
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    records[index].emailDrafts = drafts
                }
            }
        }
        .sheet(item: $editingAction) { target in
            ActionItemEditorView(action: target.action) { action in
                saveAction(target, action: action)
            } onCancel: {
                editingAction = nil
            }
        }
        .sheet(isPresented: $showLoadIssues) {
            UnreadableMeetingsView(issues: loadIssues)
        }
        .onChange(of: Set(displayedRecords.map(\.id))) { _, ids in
            if selection == nil || !ids.contains(selection!) {
                selection = listSections.first?.records.first?.id
            }
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
        .alert("清理这场会议的其他版本？", isPresented: Binding(
            get: { pendingVersionCleanup != nil },
            set: { if !$0 { pendingVersionCleanup = nil } }
        )) {
            Button("取消", role: .cancel) { pendingVersionCleanup = nil }
            Button("保留当前版本并清理其他版本", role: .destructive) { cleanOtherVersions() }
        } message: {
            Text("将永久删除同一源文件的其他纪要版本，只保留当前打开的版本。原始媒体不会被删除。")
        }
        .alert("回溯历史待办？", isPresented: Binding(
            get: { pendingActionReviewWorkspace != nil },
            set: { if !$0 { pendingActionReviewWorkspace = nil } }
        )) {
            Button("取消", role: .cancel) { pendingActionReviewWorkspace = nil }
            Button("开始分析") { startHistoricalActionReview() }
        } message: {
            Text("将按时间顺序分析“\(pendingActionReviewWorkspace?.name ?? "当前项目")”的后续会议，并为明确提及的历史待办生成状态建议。不会直接修改待办状态，分析会消耗大模型 Token。")
        }
    }

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会议资料库").font(.headline)
                Spacer()
                Button { showWorkspaceManager = true } label: {
                    Image(systemName: "folder.badge.gearshape")
                }.buttonStyle(.borderless).help("管理项目")
            }.padding(12)
            Divider()
            List {
                Section("智能分类") {
                    scopeRow("最近会议", icon: "clock", count: meetingCount(in: .recent), scope: .recent)
                    scopeRow("全部会议", icon: "tray.full", count: meetingCount(in: .all), scope: .all)
                    scopeRow("待办未完成", icon: "checklist", count: meetingCount(in: .pendingActions), scope: .pendingActions)
                    if !loadIssues.isEmpty {
                        Button { showLoadIssues = true } label: {
                            HStack {
                                Label("无法读取", systemImage: "exclamationmark.triangle")
                                Spacer(); Text("\(loadIssues.count)").font(.caption)
                            }.foregroundStyle(.orange)
                        }.buttonStyle(.plain)
                    }
                }
                Section("客户") {
                    ForEach(classificationCustomers, id: \.self) { customer in
                        DisclosureGroup {
                            ForEach(classificationProjects(customer: customer), id: \.self) { project in
                                DisclosureGroup {
                                    let types = classificationTypes(customer: customer, project: project)
                                    if types.isEmpty {
                                        Text("尚无会议类型标签")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .padding(.leading, 8)
                                    } else {
                                        ForEach(types, id: \.self) { type in
                                            classificationTypeRow(type, customer: customer, project: project)
                                        }
                                    }
                                } label: {
                                    Button {
                                        meetingTypeFilter = ""
                                        customerFilter = customer
                                        projectFilter = project
                                        scope = .all
                                    } label: {
                                        HStack {
                                            Label(project, systemImage: "folder")
                                            Spacer()
                                            Text("\(classificationCount(customer: customer, project: project))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } label: {
                            Button {
                                meetingTypeFilter = ""
                                customerFilter = customer
                                projectFilter = ""
                                scope = .all
                            } label: {
                                HStack {
                                    Label(customer, systemImage: "person.2")
                                    Spacer()
                                    Text("\(classificationCount(customer: customer))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.listStyle(.sidebar)
        }
    }

    private func scopeRow(_ title: String, icon: String, count: Int,
                          scope: MeetingLibraryScope) -> some View {
        Button {
            meetingTypeFilter = ""
            customerFilter = ""
            projectFilter = ""
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

    private func classificationTypeRow(_ type: String, customer: String, project: String) -> some View {
        Button {
            scope = .all
            customerFilter = customer
            projectFilter = project
            meetingTypeFilter = type
        } label: {
            HStack {
                Label(type, systemImage: "tag")
                Spacer()
                Text("\(classificationCount(customer: customer, project: project, type: type))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain)
    }

    private func meetingTypeRow(_ type: String, project: MeetingWorkspace) -> some View {
        Button {
            scope = .workspace(project.id)
            meetingTypeFilter = type
        } label: {
            HStack {
                Label(type, systemImage: "tag")
                Spacer()
                Text("\(meetingTypeCount(type, projectID: project.id))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(scope == .workspace(project.id) && meetingTypeFilter == type
                        ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }

    private var meetingList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(scopeTitle).font(.headline)
                Spacer()
                Menu {
                    Button {
                        meetingTypeFilter = ""
                        scope = scope == .favorites ? .all : .favorites
                    } label: {
                        Label("已收藏（\(MeetingLibrary.filter(records, scope: .favorites).count)）",
                              systemImage: scope == .favorites ? "checkmark" : "star")
                    }
                    Button {
                        meetingTypeFilter = ""
                        scope = scope == .archived ? .all : .archived
                    } label: {
                        Label("已归档（\(MeetingLibrary.filter(records, scope: .archived).count)）",
                              systemImage: scope == .archived ? "checkmark" : "archivebox")
                    }
                    if scope == .favorites || scope == .archived {
                        Divider()
                        Button("清除状态筛选") { meetingTypeFilter = ""; scope = .all }
                    }
                    if !availableTags.isEmpty {
                        Divider()
                        Menu("标签") {
                            ForEach(availableTags, id: \.name) { tag in
                                Button("\(tag.name)（\(tag.count)）") {
                                    meetingTypeFilter = ""
                                    scope = .meetingTag(tag.name)
                                }
                            }
                        }
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
                    }.buttonStyle(.borderless).help("项目总览与待办台账")
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
                let versions = versions(for: record)
                if versions.count > 1 {
                    Text("\(versions.count) 个版本")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text(TranscriptSegment.humanDuration(record.duration))
                Label("\(classification(record.customerName)) / \(classification(record.projectName))",
                      systemImage: "folder")
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
            VStack(alignment: .leading, spacing: 9) {
                Text(detailTitle(for: record))
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Text("\(TranscriptSegment.humanDuration(record.duration)) · \(record.createdAt.formatted())")
                    Text("·")
                    Label("\(classification(record.customerName)) / \(classification(record.projectName))",
                          systemImage: "folder")
                    if let tags = record.tags, !tags.isEmpty {
                        Text("·")
                        Text(tags.map { "#\($0)" }.joined(separator: "  "))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

                HStack(spacing: 10) {
                    Button { toggleFavorite(record) } label: {
                        Image(systemName: record.isFavorite == true ? "star.fill" : "star")
                    }.help(record.isFavorite == true ? "取消收藏" : "收藏")
                    Spacer()
                    Button("复制纪要") { copyMinutes(record) }
                    Menu("更多") {
                        Button("用默认 Markdown 应用打开") { openMinutes(record) }
                        Button("导出…") { export(record) }
                        Divider()
                        if FileManager.default.fileExists(atPath: record.sourcePath) {
                            Button("打开源文件") { NSWorkspace.shared.open(record.sourceURL) }
                            Button("重新处理") { onReprocess(record) }
                        } else {
                            Button("重新定位源文件…") { relinkSource(record) }
                        }
                        let versions = versions(for: record)
                        if versions.count > 1 {
                            Menu("历史版本（\(versions.count)）") {
                                ForEach(versions) { version in
                                    Button {
                                        selection = version.id
                                    } label: {
                                        Label(version.createdAt.formatted(date: .abbreviated, time: .shortened),
                                              systemImage: version.id == record.id ? "checkmark" : "doc")
                                    }
                                }
                                Divider()
                                Button("保留当前版本并清理其他版本…", role: .destructive) {
                                    pendingVersionCleanup = record
                                }
                            }
                        }
                        Divider()
                        Button("会议信息、归组与标签…") { editingClassification = record }
                        Button("生成同步邮件…") { emailRecord = record }
                        Button(record.isArchived == true ? "移出归档" : "归档") {
                            toggleArchived(record)
                        }
                        Divider()
                        Button("校正逐字稿、学习并重新生成…") { editingTranscript = record }
                        Button("纠正并学习识别内容…") { learningRecognition = record }
                        Button("生成双栏释义…") { translatingTranscript = record }
                        Divider()
                        Button("删除这条记录…", role: .destructive) { pendingDelete = record }
                    }
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
            MarkdownView(markdown: StructuredMinutesRenderer.markdown(for: record))
        case .actions:
            if let actions = record.structuredSummary?.actionItems, !actions.isEmpty {
                List {
                    let suggestions = pendingSuggestions(for: record)
                    if !suggestions.isEmpty {
                        Section {
                            ForEach(suggestions) { suggestion in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(suggestion.task).font(.body.weight(.medium))
                                        Spacer()
                                        Button("确认更新") { applySuggestion(record, suggestion) }
                                    }
                                    Text("\(statusText(suggestion.previousStatus)) → \(statusText(suggestion.proposedStatus))")
                                        .font(.caption).foregroundStyle(.blue)
                                    Text("依据：\(suggestion.evidence.joined(separator: "、"))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                        } header: {
                            HStack {
                                Text("历史待办状态建议")
                                Spacer()
                                Button("全部确认") { applyAllSuggestions(record) }
                                    .font(.caption).buttonStyle(.borderless)
                            }
                        }
                    }
                    Section("本次会议待办") {
                        ForEach(actions.indices, id: \.self) { index in
                            let action = actions[index]
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: action.isClosed ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(action.isClosed ? Color.green : Color.secondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(action.task).font(.body.weight(.medium))
                                        .foregroundStyle(action.isClosed ? Color.secondary : Color.primary)
                                    HStack {
                                        Label(action.owner.isEmpty ? "待确认" : action.owner, systemImage: "person")
                                        Label(action.due.isEmpty ? "待确认" : action.due, systemImage: "calendar")
                                        Text(action.status.isEmpty ? "状态待确认" : action.status)
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("编辑…") {
                                    editingAction = ActionEditTarget(
                                        meetingID: record.id, index: index, action: action)
                                }
                                .buttonStyle(.borderless)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            } else {
                ContentUnavailableView("没有结构化待办", systemImage: "checklist")
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
                LabeledContent("客户", value: classification(record.customerName))
                LabeledContent("项目名称", value: classification(record.projectName))
                LabeledContent("会议类型", value: (record.tags ?? []).isEmpty
                               ? "未设置" : (record.tags ?? []).joined(separator: "、"))
                LabeledContent("纪要模板", value: MinutesTemplate.template(id: record.minutesTemplateID).name)
                LabeledContent("模型", value: "\(record.backend) · \(record.model)")
                LabeledContent("源文件", value: record.sourcePath)
                if let materials = record.materials, !materials.isEmpty {
                    LabeledContent("会前材料", value: materials.map(\.name).joined(separator: "、"))
                }
                if let stats = record.adaptiveScreenReviewStats {
                    LabeledContent("画面补充分析", value: stats.summary)
                }
            }.formStyle(.grouped)
        }
    }

    private var scopeTitle: String {
        if !customerFilter.isEmpty {
            let parts = [customerFilter, projectFilter, meetingTypeFilter].filter { !$0.isEmpty }
            return parts.joined(separator: " · ")
        }
        switch scope {
        case .all: return "全部会议"
        case .recent: return "最近会议"
        case .pendingActions: return "待办未完成"
        case .favorites: return "已收藏"
        case .archived: return "已归档"
        case .customer(let id): return workspaces.first { $0.id == id }?.name ?? "客户"
        case .workspace(let id):
            let project = workspaces.first { $0.id == id }?.name ?? "项目"
            return meetingTypeFilter.isEmpty ? project : "\(project) · \(meetingTypeFilter)"
        case .meetingTag(let tag): return "标签 · \(tag)"
        }
    }

    private var listSections: [MeetingLibrarySection] {
        MeetingLibrary.timeSections(displayedRecords, sort: sort)
    }

    private func load() {
        do {
            let report = try MeetingHistoryStore.loadReport()
            records = report.records
            loadIssues = report.issues
            migrateHistoricalTitlesIfNeeded()
            loadWorkspaces()
            scope = restoredScope(storedScope)
            if selection == nil || !records.contains(where: { $0.id == selection }) {
                selection = listSections.first?.records.first?.id
            }
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
        case .archived: return "archived"
        case .customer(let id): return "customer:\(id.uuidString)"
        case .workspace(let id): return "workspace:\(id.uuidString)"
        case .meetingTag(let tag): return "tag:\(tag)"
        }
    }

    private func restoredScope(_ value: String) -> MeetingLibraryScope {
        switch value {
        case "all": return .all
        case "pendingActions": return .pendingActions
        case "favorites": return .favorites
        case "ungrouped": return .recent
        case "archived": return .archived
        default:
            if value.hasPrefix("workspace:"),
               let id = UUID(uuidString: String(value.dropFirst("workspace:".count))),
               workspaces.contains(where: { $0.id == id }) {
                return .workspace(id)
            }
            if value.hasPrefix("customer:"),
               let id = UUID(uuidString: String(value.dropFirst("customer:".count))),
               workspaces.contains(where: { $0.id == id && $0.isCustomer }) {
                return .customer(id)
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

    private func versionKey(_ record: MeetingRecord) -> String {
        record.sourceURL.standardizedFileURL.path
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func versions(for record: MeetingRecord) -> [MeetingRecord] {
        let key = versionKey(record)
        return records.filter { versionKey($0) == key }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func meetingCount(in scope: MeetingLibraryScope) -> Int {
        let values: [MeetingRecord]
        if case .customer(let customerID) = scope {
            let projects = Set(workspaces.filter { $0.customerID == customerID }.map(\.id))
            values = records.filter {
                $0.isArchived != true
                    && ($0.workspaceID == customerID || $0.workspaceID.map(projects.contains) == true)
            }
        } else {
            values = MeetingLibrary.filter(records, scope: scope)
        }
        return Set(values.map(versionKey)).count
    }

    private func classification(_ value: String?) -> String {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? "未知" : cleaned
    }

    private func classificationCount(customer: String, project: String? = nil,
                                     type: String? = nil) -> Int {
        let values = classificationRecords.filter { record in
            guard classification(record.customerName) == customer else { return false }
            if let project, classification(record.projectName) != project { return false }
            if let type, !(record.tags ?? []).contains(where: {
                $0.localizedCaseInsensitiveCompare(type) == .orderedSame
            }) { return false }
            return true
        }
        return Set(values.map(versionKey)).count
    }

    private func meetingTypeCount(_ type: String, projectID: UUID) -> Int {
        let values = records.filter { record in
            record.isArchived != true && record.workspaceID == projectID
                && (record.tags ?? []).contains {
                    $0.localizedCaseInsensitiveCompare(type) == .orderedSame
                }
        }
        return Set(values.map(versionKey)).count
    }

    private func detailTitle(for record: MeetingRecord) -> String {
        let generated = record.structuredSummary?.title
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return generated.isEmpty ? record.title : generated
    }

    private var selectedFilterWorkspace: MeetingWorkspace? {
        guard case .workspace(let id) = scope else { return nil }
        return workspaces.first { $0.id == id }
    }

    private var actionReviewWorkspace: MeetingWorkspace? {
        if let selectedFilterWorkspace { return selectedFilterWorkspace }
        guard let id = selected?.workspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    private func startHistoricalActionReview() {
        guard let workspace = pendingActionReviewWorkspace else { return }
        pendingActionReviewWorkspace = nil
        isReviewingActions = true
        error = nil
        exportMessage = "正在准备“\(workspace.name)”的历史待办回溯…"
        let snapshot = records
        Task {
            do {
                let result = try await HistoricalActionReviewService(settings: .shared).run(
                    records: snapshot, workspaceID: workspace.id
                ) { message in
                    Task { @MainActor in exportMessage = message }
                }
                for updated in result.updatedRecords {
                    if let index = records.firstIndex(where: { $0.id == updated.id }) {
                        records[index] = updated
                    }
                }
                exportMessage = result.reviewedMeetings == 0
                    ? "没有需要回溯的历史待办。"
                    : "回溯完成：检查 \(result.reviewedMeetings) 场后续会议，生成 \(result.suggestions) 条待确认建议。"
                if result.suggestions > 0 {
                    selection = result.updatedRecords.last?.id
                    detailTab = .actions
                }
            } catch {
                self.error = "历史待办回溯失败：\(error.localizedDescription)"
            }
            isReviewingActions = false
        }
    }

    private func migrateHistoricalTitlesIfNeeded() {
        let key = "meetingHistory.didMigrateTitlesAndDates.v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let candidates = records.compactMap { record -> (MeetingRecord, String?, Date?)? in
            let title = MeetingTitleResolver.historicalTitle(for: record)
            let fileDate = MeetingDateResolver.recordedAtIfAvailable(for: record.sourceURL)
            let date = fileDate.flatMap {
                abs($0.timeIntervalSince(record.createdAt)) > 1 ? $0 : nil
            }
            guard title != nil || date != nil else { return nil }
            return (record, title, date)
        }
        do {
            for (record, title, date) in candidates {
                let updated = try MeetingHistoryStore.updateClassification(
                    id: record.id, title: title, createdAt: date,
                    workspaceID: record.workspaceID,
                    customerName: record.customerName,
                    projectName: record.projectName,
                    tags: record.tags ?? [])
                if let index = records.firstIndex(where: { $0.id == updated.id }) {
                    records[index] = updated
                }
            }
            UserDefaults.standard.set(true, forKey: key)
            if !candidates.isEmpty {
                exportMessage = "已自动整理 \(candidates.count) 条存量会议的名称或日期。"
            }
        } catch {
            self.error = "存量会议名称自动整理失败：\(error.localizedDescription)"
        }
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

    private func saveAction(_ target: ActionEditTarget,
                            action: StructuredMinutes.ActionItem) {
        do {
            let updated = try MeetingHistoryStore.updateActionItem(
                id: target.meetingID, index: target.index, action: action)
            if let index = records.firstIndex(where: { $0.id == updated.id }) {
                records[index] = updated
            }
            editingAction = nil
            error = nil
        } catch {
            self.error = "待办保存失败：\(error.localizedDescription)"
        }
    }

    private func pendingSuggestions(for record: MeetingRecord) -> [ActionStatusSuggestion] {
        let applied = Set(record.appliedActionSuggestionIDs ?? [])
        return (record.actionStatusSuggestions ?? []).filter { !applied.contains($0.id) }
    }

    private func applySuggestion(_ record: MeetingRecord, _ suggestion: ActionStatusSuggestion) {
        do {
            for updated in try MeetingHistoryStore.applyActionSuggestion(
                sourceMeetingID: record.id, suggestionID: suggestion.id) {
                if let index = records.firstIndex(where: { $0.id == updated.id }) {
                    records[index] = updated
                }
            }
            error = nil
        } catch { self.error = "状态更新失败：\(error.localizedDescription)" }
    }

    private func applyAllSuggestions(_ record: MeetingRecord) {
        for suggestion in pendingSuggestions(for: record) {
            applySuggestion(records.first(where: { $0.id == record.id }) ?? record, suggestion)
        }
    }

    private func statusText(_ value: String) -> String { value.isEmpty ? "待确认" : value }

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

    private func copyMinutes(_ record: MeetingRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            StructuredMinutesRenderer.markdown(for: record), forType: .string)
        exportMessage = "纪要已复制"
        error = nil
    }

    private func openMinutes(_ record: MeetingRecord) {
        do {
            try MinutesDocumentOpener.open(
                markdown: StructuredMinutesRenderer.markdown(for: record),
                title: detailTitle(for: record))
            error = nil
        } catch {
            self.error = "打开纪要失败：\(error.localizedDescription)"
        }
    }

    private func relinkSource(_ record: MeetingRecord) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "重新关联"
        panel.message = "请选择这场会议对应的原始录音或录像。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let probe = try await MediaExtractor(url: url).probe()
                let tolerance = max(10, record.duration * 0.08)
                guard abs(probe.duration - record.duration) <= tolerance else {
                    self.error = "所选文件时长与原会议不符，请选择正确的录音或录像。"
                    return
                }
                let linkedVersions = versions(for: record)
                for version in linkedVersions {
                    let updated = try MeetingHistoryStore.updateSourcePath(
                        id: version.id, sourcePath: url.path)
                    if let index = records.firstIndex(where: { $0.id == version.id }) {
                        records[index] = updated
                    }
                }
                exportMessage = "已为 \(linkedVersions.count) 个版本重新关联源文件"
                error = nil
            } catch {
                self.error = "无法验证或重新关联所选文件：\(error.localizedDescription)"
            }
        }
    }

    private func cleanOtherVersions() {
        guard let kept = pendingVersionCleanup else { return }
        pendingVersionCleanup = nil
        let obsolete = versions(for: kept).filter { $0.id != kept.id }
        do {
            for record in obsolete { try MeetingHistoryStore.remove(id: record.id) }
            let removed = Set(obsolete.map(\.id))
            records.removeAll { removed.contains($0.id) }
            selection = kept.id
            exportMessage = "已清理 \(obsolete.count) 个其他版本"
            error = nil
        } catch {
            self.error = "版本清理失败：\(error.localizedDescription)"
            load()
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

private struct UnreadableMeetingsView: View {
    @Environment(\.dismiss) private var dismiss
    let issues: [MeetingHistoryStore.LoadIssue]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("无法读取的会议").font(.title3.weight(.semibold))
                    Text("这些记录仍保留在磁盘中，没有被自动删除。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(); Button("完成") { dismiss() }
            }.padding(18)
            Divider()
            List(issues) { issue in
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.directory.lastPathComponent).font(.callout.weight(.medium))
                    Text(issue.reason).font(.caption).foregroundStyle(.orange)
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([issue.directory])
                    }.buttonStyle(.link)
                }.padding(.vertical, 5)
            }
        }.frame(width: 620, height: 420)
    }
}
