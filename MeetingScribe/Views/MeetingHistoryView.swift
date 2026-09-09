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
    @State private var editingSpeakers: MeetingRecord?
    @State private var minutesVersionRecord: MeetingRecord?
    @State private var editingAction: ActionEditTarget?
    @State private var detailTab: DetailTab = .customer
    @State private var meetingTypeFilter = ""
    @State private var customerFilter = ""
    @State private var projectFilter = ""
    @State private var showLoadIssues = false
    @State private var pendingVersionCleanup: MeetingRecord?
    @State private var showsLibrarySidebar = true
    @State private var showsMeetingList = true

    init(initialSelection: UUID? = nil,
         onReprocess: @escaping (MeetingRecord) -> Void,
         onAnalyzeTranscript: @escaping (MeetingRecord, Transcript) -> Void) {
        self.onReprocess = onReprocess
        self.onAnalyzeTranscript = onAnalyzeTranscript
        _selection = State(initialValue: initialSelection)
    }

    private enum DetailTab: String, CaseIterable {
        case customer = "会议纪要", actions = "待办", info = "信息"
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
            return versions.max { versionSortDate($0) < versionSortDate($1) }
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
                if showsLibrarySidebar {
                    librarySidebar
                        .frame(minWidth: 180, idealWidth: 205, maxWidth: 240)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if showsMeetingList {
                    meetingList
                        .frame(minWidth: 270, idealWidth: 310, maxWidth: 370)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
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
        .sheet(item: $editingSpeakers) { record in
            HistoricalSpeakerEditorView(record: record) { names, roles, regenerate in
                do {
                    let updated = try MeetingHistoryStore.updateSpeakers(
                        id: record.id, names: names, roles: roles)
                    if let index = records.firstIndex(where: { $0.id == updated.id }) {
                        records[index] = updated
                    }
                    editingSpeakers = nil
                    if regenerate { onReprocess(updated) }
                } catch { self.error = "说话人信息保存失败：\(error.localizedDescription)" }
            } onCancel: { editingSpeakers = nil }
        }
        .sheet(item: $minutesVersionRecord) { record in
            MeetingMinutesVersionView(
                meetingID: record.id, title: record.title,
                minutes: CustomerMinutesRenderer.markdown(for: record),
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
        .onChange(of: selection) { _, _ in detailTab = .customer }
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
            if let kept = pendingVersionCleanup {
                Text("将保留：\(versionLabel(kept))。其他 \(max(versions(for: kept).count - 1, 0)) 个版本将被删除；原始媒体不会被删除。")
            }
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
                if record.emailDrafts?.hongKongTraditional.isEmpty == false {
                    Image(systemName: "character.book.closed.fill").foregroundStyle(.secondary)
                }
                if record.structuredSummary == nil {
                    Label("基础纪要", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                        .help("该版本没有结构化问题和待办能力")
                }
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
                    Button {
                        withAnimation { showsLibrarySidebar.toggle() }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help(showsLibrarySidebar ? "收起分类栏" : "展开分类栏")
                    Button {
                        withAnimation { showsMeetingList.toggle() }
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .help(showsMeetingList ? "收起会议列表" : "展开会议列表")
                    Button { toggleFavorite(record) } label: {
                        Image(systemName: record.isFavorite == true ? "star.fill" : "star")
                    }.help(record.isFavorite == true ? "取消收藏" : "收藏")
                    Spacer()
                    if let workspace = workspace(for: record) {
                        let count = pendingIssueProposalCount(for: workspace.id)
                        Button(count > 0 ? "问题关联（\(count)）" : "项目问题") {
                            dashboardWorkspace = workspace
                        }
                        .help(count > 0 ? "打开需要确认的问题关联" : "打开项目问题档案")
                    }
                    Menu("更多") {
                        Button("编辑会议信息…") { editingClassification = record }
                        Menu("导出会议资料") {
                            Button("会议纪要…") {
                                exportText(CustomerMinutesRenderer.markdown(for: record),
                                           suggestedName: "\(record.title) 会议纪要.md")
                            }
                            Button("内部完整纪要…") {
                                exportText(StructuredMinutesRenderer.markdown(for: record),
                                           suggestedName: "\(record.title) 内部完整纪要.md")
                            }
                            Button("逐字稿…") {
                                exportText(record.transcript.timecodedText,
                                           suggestedName: "\(record.title) 逐字稿.txt")
                            }
                            Divider()
                            Button("全部会议资料…") { export(record) }
                        }
                        Divider()
                        if !record.speakerNames.isEmpty || !(record.speakerRoles ?? [:]).isEmpty {
                            Button("修改说话人姓名与角色…") { editingSpeakers = record }
                        }
                        if FileManager.default.fileExists(atPath: record.sourcePath) {
                            Button("打开源文件") { NSWorkspace.shared.open(record.sourceURL) }
                            Button("重新处理") { onReprocess(record) }
                        } else if record.sourceKind == MeetingAssets.SourceKind.importedTranscript.rawValue {
                            Button("使用内部逐字稿重新生成") { onReprocess(record) }
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
                                        Label(versionLabel(version),
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
                        Button("校正识别并重新生成…") { editingTranscript = record }
                        Divider()
                        Button(record.isArchived == true ? "移出归档" : "归档") {
                            toggleArchived(record)
                        }
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
        case .customer:
            VStack(spacing: 0) {
                MarkdownView(markdown: CustomerMinutesRenderer.markdown(for: record))
                Divider()
                HStack {
                    Spacer()
                    Button("打开 Markdown", systemImage: "doc.text") {
                        do {
                            try MinutesDocumentOpener.open(
                                markdown: CustomerMinutesRenderer.markdown(for: record),
                                title: record.title)
                        } catch let openError {
                            error = "打开纪要失败：\(openError.localizedDescription)"
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        case .actions:
            if let actions = record.structuredSummary?.actionItems, !actions.isEmpty {
                List {
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
                if let usage = record.generationUsage {
                    Section("本次生成用量") {
                        LabeledContent("总 Token", value: usage.totalTokens.formatted())
                        LabeledContent("输入 / 输出",
                                       value: "\(usage.inputTokens.formatted()) / \(usage.outputTokens.formatted())")
                        LabeledContent("模型调用", value: "\(usage.calls) 次")
                        ForEach(usage.phases) { phase in
                            LabeledContent(phase.name,
                                           value: "\((phase.inputTokens + phase.outputTokens).formatted()) Token")
                        }
                        if usage.isEstimated {
                            Text("估算值：根据实际发送和返回的文本计算；CLI、推理 Token、图片 Token及供应商缓存计费可能存在差异。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup("内部完整纪要（仅供内部查看）") {
                    Text("包含参会角色判断、证据引用、会后非正式内容和待核对信息，请勿在客户面前展开。")
                        .font(.caption).foregroundStyle(.orange)
                    MarkdownView(markdown: StructuredMinutesRenderer.markdown(for: record))
                        .frame(height: 420)
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

    private func pendingIssueProposalCount(for workspaceID: UUID) -> Int {
        (try? ProjectLedgerStore.load().pendingIssueProposals(for: workspaceID).count) ?? 0
    }

    private func versionKey(_ record: MeetingRecord) -> String {
        if let id = record.meetingGroupID { return "meeting:\(id.uuidString.lowercased())" }
        return record.sourceURL.standardizedFileURL.path
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func versions(for record: MeetingRecord) -> [MeetingRecord] {
        let key = versionKey(record)
        return records.filter { versionKey($0) == key }
            .sorted { versionSortDate($0) > versionSortDate($1) }
    }

    private func versionSortDate(_ record: MeetingRecord) -> Date {
        record.generatedAt ?? (record.structuredSummary == nil ? .distantPast : record.createdAt)
    }

    private func versionLabel(_ record: MeetingRecord) -> String {
        let state = record.structuredSummary == nil ? "未生成纪要" : "已生成纪要"
        let time = record.generatedAt?.formatted(date: .abbreviated, time: .standard)
            ?? "历史版本"
        return "\(state) · \(time) · \(record.id.uuidString.prefix(6))"
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
            let key = versionKey(record)
            for index in records.indices where versionKey(records[index]) == key {
                if let favorite { records[index].isFavorite = favorite }
                if let archived { records[index].isArchived = archived }
            }
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

    private func removePending() {
        guard let record = pendingDelete else { return }
        pendingDelete = nil
        var staged: URL?
        do {
            staged = try MeetingHistoryStore.stageRemoval(id: record.id)
            try ProjectLedgerStore.removePendingReferences(to: [record.id])
            MeetingHistoryStore.finalizeRemoval(stagedAt: staged)
            records.removeAll { $0.id == record.id }
            selection = records.first?.id
            error = nil
        } catch {
            if let staged { try? MeetingHistoryStore.restoreRemoval(id: record.id, stagedAt: staged) }
            self.error = "删除失败：\(error.localizedDescription)"
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
        guard kept.structuredSummary != nil
                || !obsolete.contains(where: { $0.structuredSummary != nil }) else {
            error = "当前选中的是“未生成纪要”版本。为避免误删，请先在历史版本菜单中选择“已生成纪要”版本。"
            return
        }
        var staged: [(UUID, URL)] = []
        do {
            for record in obsolete {
                if let url = try MeetingHistoryStore.stageRemoval(id: record.id) {
                    staged.append((record.id, url))
                }
            }
            let removed = Set(obsolete.map(\.id))
            try ProjectLedgerStore.removePendingReferences(to: removed)
            staged.forEach { MeetingHistoryStore.finalizeRemoval(stagedAt: $0.1) }
            records.removeAll { removed.contains($0.id) }
            selection = kept.id
            exportMessage = "已清理 \(obsolete.count) 个其他版本"
            error = nil
        } catch {
            for (id, url) in staged.reversed() {
                try? MeetingHistoryStore.restoreRemoval(id: id, stagedAt: url)
            }
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

    private func exportText(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "已导出到 \(url.path)"
            error = nil
        } catch {
            self.error = "导出失败：\(error.localizedDescription)"
        }
    }
}

private struct HistoricalSpeakerEditorView: View {
    let record: MeetingRecord
    let onSave: ([Int: String], [Int: SpeakerRole], Bool) -> Void
    let onCancel: () -> Void

    @State private var names: [Int: String]
    @State private var roles: [Int: SpeakerRole]

    init(record: MeetingRecord,
         onSave: @escaping ([Int: String], [Int: SpeakerRole], Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.record = record; self.onSave = onSave; self.onCancel = onCancel
        _names = State(initialValue: record.speakerNames)
        _roles = State(initialValue: record.speakerRoles ?? [:])
    }

    private var speakerIDs: [Int] {
        Array(Set(names.keys).union(roles.keys)).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("修改说话人姓名与角色").font(.title3.weight(.semibold))
                Text("修改可只保存到记录，也可以携带这些信息重新生成纪要；同名说话人的角色会自动同步。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            List(speakerIDs, id: \.self) { speaker in
                VStack(alignment: .leading, spacing: 8) {
                    Text("说话人 \(speaker + 1)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("姓名", text: Binding(
                            get: { names[speaker] ?? "" },
                            set: { names[speaker] = $0 }
                        ))
                        Picker("所属方", selection: Binding(
                            get: { roles[speaker]?.affiliation ?? .unknown },
                            set: { value in
                                var role = roles[speaker] ?? SpeakerRole()
                                role.affiliation = value
                                roles = SpeakerRole.applying(
                                    role, to: speaker, names: names, roles: roles)
                            }
                        )) {
                            ForEach(SpeakerRole.Affiliation.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("角色", selection: Binding(
                            get: { roles[speaker]?.meetingRole ?? .unknown },
                            set: { value in
                                var role = roles[speaker] ?? SpeakerRole()
                                role.meetingRole = value
                                roles = SpeakerRole.applying(
                                    role, to: speaker, names: names, roles: roles)
                            }
                        )) {
                            ForEach(SpeakerRole.MeetingRole.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }.padding(.vertical, 5)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("仅保存") { save(regenerate: false) }
                Button("保存并重新生成") { save(regenerate: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!FileManager.default.fileExists(atPath: record.sourcePath)
                              && record.sourceKind != MeetingAssets.SourceKind.importedTranscript.rawValue)
            }.padding(14)
        }.frame(width: 720, height: 500)
    }

    private func save(regenerate: Bool) {
        let cleanedNames = names.compactMapValues { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        onSave(cleanedNames, roles.filter { $0.value.isSpecified }, regenerate)
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
