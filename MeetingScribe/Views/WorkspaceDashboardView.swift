import SwiftUI

struct WorkspaceDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: MeetingWorkspace
    let records: [MeetingRecord]
    var onOpenMeeting: ((UUID) -> Void)? = nil
    @State private var ledger = ProjectLedger()
    @State private var ledgerError: String?
    @State private var editingProposal: ProjectActionProposal?
    @State private var editingIssueProposal: ProjectIssueProposal?
    @State private var editingIssueStatus: ProjectIssue?
    @State private var analyzingIssue: ProjectIssue?
    @State private var selectedProposalIDs = Set<UUID>()

    private var insights: WorkspaceInsights { WorkspaceInsights(records: records) }
    // Legacy ledger values remain decodable so existing data is not destroyed. They are no
    // longer surfaced as a task workflow or populated for new meetings.
    private var actions: [ProjectAction] { ledger.actions(for: workspace.id) }
    private var openActions: [ProjectAction] { actions.filter { !$0.isClosed } }
    private var overdueActions: [ProjectAction] { openActions.filter(\.isOverdue) }
    private var blockedActions: [ProjectAction] { openActions.filter(\.isBlocked) }
    private var proposals: [ProjectActionProposal] { ledger.pendingProposals(for: workspace.id) }
    private var issues: [ProjectIssue] { ledger.issues(for: workspace.id) }
    private var openIssues: [ProjectIssue] { issues.filter { !$0.isClosed } }
    private var closedIssues: [ProjectIssue] { issues.filter(\.isClosed) }
    private var issueProposals: [ProjectIssueProposal] {
        ledger.pendingIssueProposals(for: workspace.id)
    }
    private var acceptedIssueProposals: [ProjectIssueProposal] {
        ledger.acceptedIssueProposals(for: workspace.id)
    }
    private struct ActionGroup: Identifiable {
        let id: String
        let title: String
        let actions: [MeetingActionInfo]
    }
    private struct ProposalGroup: Identifiable {
        let id: String
        let title: String
        let proposals: [ProjectActionProposal]
    }
    private struct MeetingActionInfo: Identifiable {
        let id: String
        let meetingID: UUID
        let meetingTitle: String
        let meetingDate: Date
        let action: StructuredMinutes.ActionItem
    }
    private var meetingActions: [MeetingActionInfo] {
        records.flatMap { record in
            (record.structuredSummary?.actionItems ?? []).enumerated().map { index, action in
                MeetingActionInfo(id: "\(record.id.uuidString)-\(index)", meetingID: record.id,
                                  meetingTitle: record.title, meetingDate: record.createdAt,
                                  action: action)
            }
        }.sorted { $0.meetingDate > $1.meetingDate }
    }
    private var actionGroups: [ActionGroup] {
        Dictionary(grouping: meetingActions, by: { $0.action.issueID }).map { issueID, values in
            ActionGroup(id: issueID ?? "independent", title: issueTitle(for: issueID), actions: values)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var proposalGroups: [ProposalGroup] {
        grouped(proposals).map { issueID, values in
            ProposalGroup(id: issueID ?? "independent", title: issueTitle(for: issueID),
                          proposals: values)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.name).font(.title2.weight(.semibold))
                    Text("\(workspace.kind.label) · \(records.count) 场会议")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        metric("会议", value: records.count, icon: "calendar")
                        metric("待确认问题", value: issueProposals.count,
                               icon: "tray.and.arrow.down")
                        metric("纪要待办", value: meetingActions.count, icon: "checklist")
                    }
                    if let ledgerError {
                        Label(ledgerError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if !workspace.context.isEmpty {
                        GroupBox("长期背景") {
                            Text(workspace.context).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4).textSelection(.enabled)
                        }
                    }
                    issueProposalSection
                    acceptedIssueProposalSection
                    sectionTitle("持续跟进问题", count: openIssues.count)
                    if openIssues.isEmpty {
                        Text(issueProposals.isEmpty ? "还没有项目问题档案" : "确认上方建议后将建立问题档案")
                            .foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(openIssues) { issue in projectIssueRow(issue) }
                    }
                    closedIssueSection
                    sectionTitle("纪要待办（信息）", count: meetingActions.count)
                    Text("来自各次会议纪要，仅用于回看，不跟踪状态，也不产生待确认更新。")
                        .font(.caption).foregroundStyle(.secondary)
                    if meetingActions.isEmpty {
                        Text("还没有会议待办")
                            .foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(actionGroups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title).font(.subheadline.weight(.semibold))
                                ForEach(group.actions) { item in
                                    Button { onOpenMeeting?(item.meetingID) } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.action.task).font(.callout.weight(.medium))
                                            HStack {
                                                Text(item.action.owner.isEmpty ? "负责人待明确" : item.action.owner)
                                                if !item.action.due.isEmpty { Text("截止：\(item.action.due)") }
                                                Text("来源：\(item.meetingTitle)")
                                            }.font(.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    sectionTitle("会议时间线", count: insights.records.count)
                    ForEach(insights.records) { record in
                        Button {
                            onOpenMeeting?(record.id)
                        } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "circle.fill").font(.system(size: 7))
                                .foregroundStyle(Color.accentColor).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.title).font(.callout.weight(.medium))
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let tags = record.tags, !tags.isEmpty {
                                    Text(tags.map { "#\($0)" }.joined(separator: "  "))
                                        .font(.caption2).foregroundStyle(Color.accentColor)
                                }
                            }
                            Spacer()
                        }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
            }
        }
        .frame(width: 820, height: 720)
        .onAppear(perform: loadLedger)
        .onChange(of: proposals.map(\.id)) { _, ids in
            selectedProposalIDs.formIntersection(ids)
            if selectedProposalIDs.isEmpty { selectedProposalIDs = defaultSelectedProposalIDs }
        }
        .sheet(item: $editingProposal) { proposal in
            ActionItemEditorView(action: .init(
                trackingID: proposal.targetActionID,
                issueID: proposal.issueID,
                owner: proposal.owner, task: proposal.task, status: proposal.status,
                due: proposal.due, evidence: proposal.evidence
            )) { action in
                var edited = proposal
                edited.task = action.task; edited.owner = action.owner
                edited.status = action.status; edited.due = action.due
                resolve(edited, accept: true, originalID: proposal.id)
                editingProposal = nil
            } onCancel: { editingProposal = nil }
        }
        .sheet(item: $editingIssueProposal) { proposal in
            IssueAssociationEditorView(proposal: proposal, issues: issues) { choice in
                resolveIssueAssociation(proposal, choice: choice)
                editingIssueProposal = nil
            } onCancel: { editingIssueProposal = nil }
        }
        .sheet(item: $editingIssueStatus) { issue in
            IssueStatusEditorView(issue: issue) { status, note in
                updateIssueStatus(issue, status: status, note: note)
                editingIssueStatus = nil
            } onCancel: { editingIssueStatus = nil }
        }
        .sheet(item: $analyzingIssue) { issue in
            ProjectIssueAnalysisView(
                issue: issue, records: records,
                existingAnalysis: ledger.analysis(for: issue.id)) { updated in
                    ledger = updated
                }
        }
    }

    private func metric(_ title: String, value: Int, icon: String) -> some View {
        GroupBox {
            HStack {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("\(value)").font(.title2.weight(.semibold))
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(4)
        }.frame(maxWidth: .infinity)
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack { Text(title).font(.headline); Text("\(count)").foregroundStyle(.secondary) }
    }

    private func actionRow(_ action: WorkspaceInsights.Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle").foregroundStyle(.orange).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(action.task).font(.callout)
                HStack(spacing: 8) {
                    Text(action.owner)
                    if !action.due.isEmpty { Text("截止：\(action.due)") }
                    if !action.status.isEmpty { Text(action.status) }
                    Text(action.meetingTitle)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func projectActionRow(_ action: ProjectAction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: action.isBlocked ? "exclamationmark.octagon.fill" : "circle")
                .foregroundStyle(action.isBlocked ? Color.red : (action.isOverdue ? .orange : .secondary))
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(action.task).font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    Label(action.owner.isEmpty ? "待明确" : action.owner, systemImage: "person")
                    if !action.due.isEmpty { Label(action.due, systemImage: "calendar") }
                    Text(action.status.isEmpty ? "待确认" : action.status)
                    if action.isOverdue { Text("已逾期").foregroundStyle(.orange) }
                }.font(.caption).foregroundStyle(.secondary)
                if let latest = action.events.last {
                    Text("最近更新：\(latest.meetingTitle) · \(latest.evidence.joined(separator: "、"))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func projectIssueRow(_ issue: ProjectIssue) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !issue.background.isEmpty { LabeledContent("背景", value: issue.background) }
                if !issue.rootCause.isEmpty { LabeledContent("根因", value: issue.rootCause) }
                if !issue.solution.isEmpty { LabeledContent("方案", value: issue.solution) }
                let linkedActions = actions.filter { $0.issueID == issue.id }
                if !linkedActions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("关联待办（\(linkedActions.count)）")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(linkedActions) { action in
                            HStack {
                                Image(systemName: action.isClosed ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(action.isClosed ? .green : .orange)
                                Text(action.task).font(.callout)
                                Spacer()
                                Text(action.owner.isEmpty ? "待明确" : action.owner)
                                Text(action.status.isEmpty ? "待确认" : action.status)
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
                ForEach(issue.events.sorted(by: { $0.occurredAt > $1.occurredAt })) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.meetingTitle).font(.caption.weight(.semibold))
                        Text(event.occurredAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2).foregroundStyle(.secondary)
                        if !event.progress.isEmpty { Text(event.progress).font(.callout) }
                    }.padding(.vertical, 3)
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title).font(.callout.weight(.medium))
                    Text("\(issue.status.isEmpty ? "待确认" : issue.status) · 更新于 \(issue.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                let analysis = ledger.analysis(for: issue.id)
                Button(analysis == nil ? "一键分析" :
                        (analysis?.isStale(comparedWith: issue) == true ? "重新分析" : "查看分析")) {
                    analyzingIssue = issue
                }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help(analysis?.isStale(comparedWith: issue) == true
                          ? "问题已有新进展，原分析已过期"
                          : "基于已确认关联的会议和证据生成问题专题分析")
                Button(issue.isClosed ? "重新打开" : "修改状态") {
                    editingIssueStatus = issue
                }
                .buttonStyle(.borderless).controlSize(.small)
            }
        }
        .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var closedIssueSection: some View {
        if !closedIssues.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("已闭环问题仍保留完整背景、方案和会议进展，不再作为后续纪要的未完成上下文。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(closedIssues) { issue in projectIssueRow(issue) }
                }.padding(.top, 8)
            } label: {
                HStack {
                    Label("已闭环问题", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(closedIssues.count)").foregroundStyle(.secondary)
                }.font(.headline)
            }
        }
    }

    @ViewBuilder
    private var issueProposalSection: some View {
        if !issueProposals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("待确认的问题", count: issueProposals.count)
                Text("确认后才会建立或更新跨会议问题档案；历史背景会在后续纪要生成时作为上下文使用。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(issueProposals) { proposal in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(proposal.kind == .create ? "新增问题" : "关联历史问题")
                                .font(.caption.weight(.semibold)).foregroundStyle(.purple)
                            Spacer()
                            Button("忽略") { resolveIssue(proposal, accept: false) }
                                .buttonStyle(.borderless)
                            Button("更改关联") { editingIssueProposal = proposal }
                                .buttonStyle(.borderless)
                            Button("确认") { resolveIssue(proposal, accept: true) }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                        Text(proposal.title).font(.callout.weight(.medium))
                        if !proposal.background.isEmpty {
                            Text("背景：\(proposal.background)").font(.caption)
                        }
                        if !proposal.progress.isEmpty {
                            Text("本次进展：\(proposal.progress)").font(.caption)
                        }
                        HStack {
                            if let previous = proposal.previousStatus {
                                Text("\(previous.isEmpty ? "待确认" : previous) → \(proposal.status.isEmpty ? "待确认" : proposal.status)")
                            } else {
                                Text("状态：\(proposal.status.isEmpty ? "待确认" : proposal.status)")
                            }
                            Text("来源：\(proposal.meetingTitle)")
                        }.font(.caption2).foregroundStyle(.secondary)
                        if proposal.kind == .update,
                           let targetID = proposal.targetIssueID,
                           let historicalIssue = issues.first(where: { $0.id == targetID }) {
                            ProjectIssueHistorySummaryView(issue: historicalIssue)
                                .padding(.top, 4)
                        }
                    }.padding(12).background(Color.purple.opacity(0.06),
                                             in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private var acceptedIssueProposalSection: some View {
        if !acceptedIssueProposals.isEmpty {
            DisclosureGroup("已确认的问题关联（\(acceptedIssueProposals.count)）") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("确认有误时，可撤销该次写入并重新选择关联问题。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(acceptedIssueProposals) { proposal in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(proposal.title).font(.callout.weight(.medium))
                                Text("\(proposal.meetingTitle) · \(proposal.meetingDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("撤销并修改") { reopenAndEditIssue(proposal) }
                                .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var proposalSection: some View {
        if !proposals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionTitle("待确认的待办", count: proposals.count)
                    Spacer()
                    Button(selectedProposalIDs.count == proposals.count ? "取消全选" : "全选") {
                        selectedProposalIDs = selectedProposalIDs.count == proposals.count
                            ? [] : Set(proposals.map(\.id))
                    }.buttonStyle(.borderless)
                    Button("批量忽略") { resolveSelected(accept: false) }
                        .disabled(selectedProposalIDs.isEmpty)
                    Button("确认所选（\(selectedProposalIDs.count)）") {
                        resolveSelected(accept: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedProposalIDs.isEmpty)
                }
                Text("新增和普通信息补全已默认勾选；可取消高风险或存疑项，再一次确认写入项目台账。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(proposalGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title).font(.subheadline.weight(.semibold))
                        ForEach(group.proposals) { proposal in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Button {
                                        if selectedProposalIDs.contains(proposal.id) {
                                            selectedProposalIDs.remove(proposal.id)
                                        } else { selectedProposalIDs.insert(proposal.id) }
                                    } label: {
                                        Image(systemName: selectedProposalIDs.contains(proposal.id)
                                              ? "checkmark.square.fill" : "square")
                                    }.buttonStyle(.plain)
                                    Text(proposal.kind == .create ? "新增待办" : "更新待办")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                                    Spacer()
                                    Button("忽略") { resolve(proposal, accept: false) }.buttonStyle(.borderless)
                                    Button("修改后确认") { editingProposal = proposal }.buttonStyle(.borderless)
                                    Button("确认") { resolve(proposal, accept: true) }
                                        .buttonStyle(.borderedProminent).controlSize(.small)
                                }
                                Text(proposal.task).font(.callout.weight(.medium))
                                HStack {
                                    Text("责任人：\(proposal.owner.isEmpty ? "待明确" : proposal.owner)")
                                    if let previous = proposal.previousStatus {
                                        Text("\(previous.isEmpty ? "待确认" : previous) → \(proposal.status.isEmpty ? "待确认" : proposal.status)")
                                    } else {
                                        Text("状态：\(proposal.status.isEmpty ? "待确认" : proposal.status)")
                                    }
                                    if !proposal.due.isEmpty { Text("截止：\(proposal.due)") }
                                }.font(.caption).foregroundStyle(.secondary)
                                Text("依据：\(proposal.meetingTitle) · \(proposal.evidence.isEmpty ? "未提供时间码" : proposal.evidence.joined(separator: "、"))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(12).background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var followUpSection: some View {
        let followUps = Array((overdueActions + blockedActions).reduce(into: [String: ProjectAction]()) {
            $0[$1.id] = $1
        }.values).sorted { $0.updatedAt > $1.updatedAt }
        if !followUps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("下次会议建议跟进", count: followUps.count)
                ForEach(followUps) { action in
                    Label(action.task, systemImage: action.isOverdue ? "calendar.badge.exclamationmark" : "exclamationmark.octagon")
                        .font(.callout)
                }
            }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func loadLedger() {
        do {
            ledger = try ProjectLedgerStore.load()
            selectedProposalIDs = defaultSelectedProposalIDs
            ledgerError = nil
        }
        catch { ledgerError = "项目台账读取失败：\(error.localizedDescription)" }
    }

    private func resolve(_ proposal: ProjectActionProposal, accept: Bool,
                         originalID: UUID? = nil) {
        do {
            ledger = accept
                ? try ProjectLedgerStore.accept(proposalID: originalID ?? proposal.id,
                                                edited: proposal)
                : try ProjectLedgerStore.ignore(proposalID: originalID ?? proposal.id)
            ledgerError = nil
            selectedProposalIDs.remove(originalID ?? proposal.id)
        } catch { ledgerError = "项目更新失败：\(error.localizedDescription)" }
    }

    private func resolveSelected(accept: Bool) {
        let ids = selectedProposalIDs
        guard !ids.isEmpty else { return }
        do {
            ledger = accept
                ? try ProjectLedgerStore.accept(proposalIDs: ids)
                : try ProjectLedgerStore.ignore(proposalIDs: ids)
            selectedProposalIDs.removeAll()
            ledgerError = nil
        } catch { ledgerError = "批量处理待办失败：\(error.localizedDescription)" }
    }

    private func issueTitle(for issueID: String?) -> String {
        guard let issueID else { return "独立待办" }
        if let issue = issues.first(where: { $0.id == issueID }) { return issue.title }
        if let proposal = issueProposals.first(where: { $0.targetIssueID == issueID }) {
            return proposal.title
        }
        return "独立待办"
    }

    private var defaultSelectedProposalIDs: Set<UUID> {
        Set(proposals.filter { proposal in
            let status = proposal.status.lowercased()
            let riskyStatus = WorkspaceInsights.isClosed(status: status)
                || status.contains("阻塞") || status.contains("blocked")
                || status.contains("受阻") || status.contains("删除")
            guard !proposal.evidence.isEmpty, !riskyStatus else { return false }
            if proposal.kind == .create { return true }
            return ActionTracking.statusIdentity(proposal.previousStatus ?? "")
                == ActionTracking.statusIdentity(proposal.status)
        }.map(\.id))
    }

    private func grouped<T>(_ values: [T]) -> [(String?, [T])] {
        let pairs: [(String?, T)] = values.map { value in
            if let action = value as? ProjectAction { return (action.issueID, value) }
            if let proposal = value as? ProjectActionProposal { return (proposal.issueID, value) }
            return (nil, value)
        }
        let keys = Array(Set(pairs.compactMap(\.0))).sorted {
            issueTitle(for: $0).localizedCompare(issueTitle(for: $1)) == .orderedAscending
        }
        var result = keys.map { key in (Optional(key), pairs.filter { $0.0 == key }.map(\.1)) }
        let independent = pairs.filter { $0.0 == nil || issueTitle(for: $0.0) == "独立待办" }.map(\.1)
        result.removeAll { issueTitle(for: $0.0) == "独立待办" }
        if !independent.isEmpty { result.append((nil, independent)) }
        return result
    }

    private func resolveIssue(_ proposal: ProjectIssueProposal, accept: Bool) {
        do {
            ledger = accept
                ? try ProjectLedgerStore.acceptIssue(proposalID: proposal.id)
                : try ProjectLedgerStore.ignoreIssue(proposalID: proposal.id)
            ledgerError = nil
        } catch { ledgerError = "问题更新失败：\(error.localizedDescription)" }
    }

    private func resolveIssueAssociation(_ proposal: ProjectIssueProposal,
                                         choice: IssueAssociationEditorView.Choice) {
        do {
            switch choice {
            case .existing(let id):
                ledger = try ProjectLedgerStore.acceptIssue(proposalID: proposal.id,
                                                             targetIssueID: id)
            case .new:
                ledger = try ProjectLedgerStore.acceptIssue(proposalID: proposal.id,
                                                             createNew: true)
            }
            ledgerError = nil
        } catch { ledgerError = "问题关联失败：\(error.localizedDescription)" }
    }

    private func reopenAndEditIssue(_ proposal: ProjectIssueProposal) {
        do {
            ledger = try ProjectLedgerStore.reopenIssue(proposalID: proposal.id)
            editingIssueProposal = ledger.issueProposals.first { $0.id == proposal.id }
            ledgerError = nil
        } catch { ledgerError = "撤销问题关联失败：\(error.localizedDescription)" }
    }

    private func updateIssueStatus(_ issue: ProjectIssue, status: String, note: String) {
        do {
            ledger = try ProjectLedgerStore.updateIssueStatus(
                issueID: issue.id, status: status, note: note)
            ledgerError = nil
        } catch { ledgerError = "问题状态更新失败：\(error.localizedDescription)" }
    }

    @ViewBuilder
    private var changesSection: some View {
        if let changes = insights.latestChanges {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("本期变化").font(.headline)
                    Text("对比 \(changes.previousMeeting.title)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(changes.currentMeeting.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if changes.items.isEmpty {
                    Text("两次会议之间没有可识别的事项变化")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    ForEach(WorkspaceInsights.MeetingChanges.Kind.allCases, id: \.rawValue) { kind in
                        let rows = changes.items(of: kind)
                        if !rows.isEmpty {
                            changeGroup(kind, rows: rows)
                        }
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        } else if records.count > 1 {
            GroupBox("本期变化") {
                Text("至少需要两场包含结构化纪要的会议才能进行对比。")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    private func changeGroup(_ kind: WorkspaceInsights.MeetingChanges.Kind,
                             rows: [WorkspaceInsights.MeetingChanges.Item]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(kind.rawValue) · \(rows.count)", systemImage: changeIcon(kind))
                .font(.caption.weight(.semibold)).foregroundStyle(changeColor(kind))
            ForEach(rows) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text(item.category).font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout)
                        if kind == .statusChanged || kind == .closed {
                            Text("\(statusText(item.previousStatus)) → \(statusText(item.currentStatus))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if kind == .notMentioned {
                            Text("上期状态：\(statusText(item.previousStatus))；未自动视为已完成")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if !item.currentStatus.isEmpty {
                            Text("状态：\(item.currentStatus)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusText(_ value: String) -> String { value.isEmpty ? "未标注" : value }

    private func changeIcon(_ kind: WorkspaceInsights.MeetingChanges.Kind) -> String {
        switch kind {
        case .new: "plus.circle.fill"
        case .closed: "checkmark.circle.fill"
        case .statusChanged: "arrow.triangle.2.circlepath"
        case .ongoing: "clock.fill"
        case .notMentioned: "questionmark.circle"
        }
    }

    private func changeColor(_ kind: WorkspaceInsights.MeetingChanges.Kind) -> Color {
        switch kind {
        case .new: .blue
        case .closed: .green
        case .statusChanged: .orange
        case .ongoing: .purple
        case .notMentioned: .secondary
        }
    }
}

private struct IssueStatusEditorView: View {
    let issue: ProjectIssue
    let onSave: (String, String) -> Void
    let onCancel: () -> Void
    @State private var status: String
    @State private var note = ""

    private let statuses = ["进行中", "等待中", "待更新", "待确认", "已闭环"]

    init(issue: ProjectIssue, onSave: @escaping (String, String) -> Void,
         onCancel: @escaping () -> Void) {
        self.issue = issue; self.onSave = onSave; self.onCancel = onCancel
        _status = State(initialValue: issue.isClosed ? "进行中" : issue.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(issue.isClosed ? "重新打开问题" : "修改问题状态")
                .font(.title2.weight(.semibold))
            Text(issue.title).font(.headline)
            Picker("新状态", selection: $status) {
                ForEach(statuses, id: \.self) { Text($0).tag($0) }
            }
            TextField(issue.isClosed ? "重新打开原因或客户要求（建议填写）" : "调整原因或补充说明（建议填写）",
                      text: $note, axis: .vertical)
                .lineLimit(3...6)
            Text("本次调整会作为独立历史事件记录，不会修改原会议纪要。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") { onSave(status, note) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || status == issue.status)
            }
        }.padding(20).frame(width: 500)
    }
}

private struct IssueAssociationEditorView: View {
    enum Choice { case existing(String), new }

    let proposal: ProjectIssueProposal
    let issues: [ProjectIssue]
    let onSave: (Choice) -> Void
    let onCancel: () -> Void
    @State private var searchText = ""
    @State private var selectedIssueID: String?

    private var filteredIssues: [ProjectIssue] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return issues }
        return issues.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.aliases.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || $0.background.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("更改问题关联").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("本次问题").font(.caption).foregroundStyle(.secondary)
                Text(proposal.title).font(.headline)
                if !proposal.progress.isEmpty {
                    Text(proposal.progress).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            TextField("搜索已有问题", text: $searchText)
                .textFieldStyle(.roundedBorder)
            List(filteredIssues, selection: $selectedIssueID) { issue in
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                    Text("\(issue.status.isEmpty ? "待确认" : issue.status) · \(issue.id)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .tag(Optional(issue.id))
                .padding(.vertical, 3)
            }
            .overlay {
                if issues.isEmpty {
                    ContentUnavailableView("还没有已有问题", systemImage: "tray",
                                           description: Text("请先将较早会议中的问题确认为新问题。"))
                } else if filteredIssues.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            if let selectedIssueID,
               let selected = issues.first(where: { $0.id == selectedIssueID }) {
                ProjectIssueHistorySummaryView(issue: selected)
                    .padding(10)
                    .background(.quaternary.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("作为新问题创建") { onSave(.new) }
                Button("关联所选问题") {
                    if let selectedIssueID { onSave(.existing(selectedIssueID)) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIssueID == nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}
