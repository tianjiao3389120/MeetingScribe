import SwiftUI

struct WorkspaceDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: MeetingWorkspace
    let records: [MeetingRecord]
    var onReviewHistory: (() -> Void)? = nil
    var onOpenMeeting: ((UUID) -> Void)? = nil
    @State private var ledger = ProjectLedger()
    @State private var ledgerError: String?
    @State private var editingProposal: ProjectActionProposal?

    private var insights: WorkspaceInsights { WorkspaceInsights(records: records) }
    private var actions: [ProjectAction] { ledger.actions(for: workspace.id) }
    private var openActions: [ProjectAction] { actions.filter { !$0.isClosed } }
    private var closedActions: [ProjectAction] { actions.filter(\.isClosed) }
    private var overdueActions: [ProjectAction] { openActions.filter(\.isOverdue) }
    private var blockedActions: [ProjectAction] { openActions.filter(\.isBlocked) }
    private var proposals: [ProjectActionProposal] { ledger.pendingProposals(for: workspace.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.name).font(.title2.weight(.semibold))
                    Text("\(workspace.kind.label) · \(records.count) 场会议")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let onReviewHistory {
                    Button("回溯历史待办…") { onReviewHistory() }
                }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        metric("会议", value: records.count, icon: "calendar")
                        metric("待确认更新", value: proposals.count, icon: "tray.and.arrow.down")
                        metric("未完成", value: openActions.count, icon: "checklist")
                        metric("逾期 / 阻塞", value: overdueActions.count + blockedActions.count,
                               icon: "exclamationmark.triangle")
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
                    proposalSection
                    followUpSection
                    sectionTitle("项目行动项", count: openActions.count)
                    if openActions.isEmpty {
                        Text(proposals.isEmpty ? "还没有项目行动项" : "确认上方建议后将写入项目台账")
                            .foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(openActions) { action in projectActionRow(action) }
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
        .sheet(item: $editingProposal) { proposal in
            ActionItemEditorView(action: .init(
                trackingID: proposal.targetActionID,
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

    @ViewBuilder
    private var proposalSection: some View {
        if !proposals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("需要确认的项目更新", count: proposals.count)
                Text("会议分析不会直接修改项目台账。确认后才会形成可持续跟踪的行动项和变化记录。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(proposals) { proposal in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(proposal.kind == .create ? "新增行动项" : "更新行动项")
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
                    }.padding(12).background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
            if ledger.actions(for: workspace.id).isEmpty,
               ledger.pendingProposals(for: workspace.id).isEmpty,
               let latest = records.sorted(by: { $0.createdAt > $1.createdAt }).first {
                ledger = try ProjectLedgerStore.prepareProposals(for: latest)
            }
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
        } catch { ledgerError = "项目更新失败：\(error.localizedDescription)" }
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
