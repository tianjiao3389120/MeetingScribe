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
}
