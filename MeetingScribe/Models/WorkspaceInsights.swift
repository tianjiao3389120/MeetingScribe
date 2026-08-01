import Foundation

struct WorkspaceInsights {
    struct Action: Identifiable {
        let id: String
        let meetingID: UUID
        let meetingTitle: String
        let meetingDate: Date
        let owner: String
        let task: String
        let status: String
        let due: String
        let isClosed: Bool
    }

    let records: [MeetingRecord]
    let actions: [Action]
    let issueCount: Int
    let requirementCount: Int

    var openActions: [Action] { actions.filter { !$0.isClosed } }
    var closedActions: [Action] { actions.filter(\.isClosed) }

    init(records: [MeetingRecord]) {
        self.records = records.sorted { $0.createdAt > $1.createdAt }
        issueCount = records.reduce(0) { $0 + ($1.structuredSummary?.issues.count ?? 0) }
        requirementCount = records.reduce(0) { $0 + ($1.structuredSummary?.requirements.count ?? 0) }
        actions = records.flatMap { record in
            (record.structuredSummary?.actionItems ?? []).enumerated().map { index, item in
                Action(id: "\(record.id.uuidString)-\(index)", meetingID: record.id,
                       meetingTitle: record.title, meetingDate: record.createdAt,
                       owner: item.owner.isEmpty ? "待明确" : item.owner,
                       task: item.task, status: item.status, due: item.due,
                       isClosed: Self.isClosed(status: item.status))
            }
        }.sorted { $0.meetingDate > $1.meetingDate }
    }

    static func isClosed(status: String) -> Bool {
        let normalized = status.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["已完成", "完成", "已关闭", "关闭", "已闭环", "closed", "done", "resolved"]
            .contains { normalized.contains($0) }
    }
}
