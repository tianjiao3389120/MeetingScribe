import SwiftUI

struct WorkspaceDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: MeetingWorkspace
    let records: [MeetingRecord]

    private var insights: WorkspaceInsights { WorkspaceInsights(records: records) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.name).font(.title2.weight(.semibold))
                    Text("\(workspace.kind.label)空间 · \(records.count) 场会议")
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
                        metric("待处理", value: insights.openActions.count, icon: "checklist")
                        metric("已完成", value: insights.closedActions.count, icon: "checkmark.circle")
                        metric("问题 / 需求", value: insights.issueCount + insights.requirementCount,
                               icon: "exclamationmark.bubble")
                    }
                    if !workspace.context.isEmpty {
                        GroupBox("长期背景") {
                            Text(workspace.context).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4).textSelection(.enabled)
                        }
                    }
                    changesSection
                    sectionTitle("当前待办", count: insights.openActions.count)
                    if insights.openActions.isEmpty {
                        Text("没有待处理事项").foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(insights.openActions) { action in actionRow(action) }
                    }
                    sectionTitle("会议时间线", count: insights.records.count)
                    ForEach(insights.records) { record in
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
                        }.padding(.vertical, 5)
                    }
                }.padding(20)
            }
        }.frame(width: 780, height: 680)
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
