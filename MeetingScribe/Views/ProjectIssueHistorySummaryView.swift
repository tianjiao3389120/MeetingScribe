import SwiftUI

struct ProjectIssueHistorySummaryView: View {
    let issue: ProjectIssue
    var initiallyExpanded = false
    @State private var isExpanded: Bool

    init(issue: ProjectIssue, initiallyExpanded: Bool = false) {
        self.issue = issue
        self.initiallyExpanded = initiallyExpanded
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                detail("当前状态", issue.status.isEmpty ? "待确认" : issue.status)
                detail("背景", issue.background)
                detail("根因", issue.rootCause)
                detail("方案", issue.solution)
                if !issue.events.isEmpty {
                    Divider()
                    Text("历史进展").font(.caption.weight(.semibold))
                    ForEach(issue.events.sorted(by: { $0.occurredAt > $1.occurredAt })) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.meetingTitle) · \(event.occurredAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption.weight(.medium))
                            if !event.progress.isEmpty {
                                Text(event.progress).font(.caption).foregroundStyle(.secondary)
                            }
                            if event.previousStatus != event.currentStatus {
                                Text("状态：\(event.previousStatus ?? "待确认") → \(event.currentStatus.isEmpty ? "待确认" : event.currentStatus)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(.top, 7)
            .textSelection(.enabled)
        } label: {
            Label("查看历史问题信息", systemImage: "clock.arrow.circlepath")
                .font(.caption.weight(.medium))
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String) -> some View {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.caption)
            }
        }
    }
}
