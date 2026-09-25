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

    struct MeetingChanges {
        enum Kind: String, CaseIterable {
            case new = "新增"
            case closed = "已完成"
            case statusChanged = "状态变化"
            case ongoing = "持续未结"
            case notMentioned = "本次未提及"
        }

        struct Item: Identifiable {
            let id: String
            let kind: Kind
            let category: String
            let title: String
            let previousStatus: String
            let currentStatus: String
        }

        let currentMeeting: MeetingRecord
        let previousMeeting: MeetingRecord
        let items: [Item]

        func items(of kind: Kind) -> [Item] { items.filter { $0.kind == kind } }
    }

    let records: [MeetingRecord]
    let actions: [Action]
    let issueCount: Int
    let requirementCount: Int

    /// Latest occurrence of each task is its current ledger state. Older mentions
    /// remain in `actions` as history but must not inflate the dashboard totals.
    var currentActions: [Action] {
        var seen = Set<String>()
        return actions.filter { action in
            let key = Self.identity(action.task)
            guard !key.isEmpty, seen.insert(key).inserted else { return false }
            return true
        }
    }
    var openActions: [Action] { currentActions.filter { !$0.isClosed } }
    var closedActions: [Action] { currentActions.filter(\.isClosed) }

    var latestChanges: MeetingChanges? {
        let comparable = records.filter { $0.structuredSummary != nil }
        guard comparable.count >= 2,
              let current = comparable[0].structuredSummary,
              let previous = comparable[1].structuredSummary else { return nil }

        var items: [MeetingChanges.Item] = []
        items += Self.compare(
            category: "问题",
            current: current.issues.map { ComparableItem(title: $0.title, status: $0.status) },
            previous: previous.issues.map { ComparableItem(title: $0.title, status: $0.status) })
        items += Self.compare(
            category: "需求",
            current: current.requirements.map { ComparableItem(title: $0.title, status: $0.status) },
            previous: previous.requirements.map { ComparableItem(title: $0.title, status: $0.status) })
        items += Self.compare(
            category: "待办",
            current: current.actionItems.map { ComparableItem(title: $0.task, status: $0.status) },
            previous: previous.actionItems.map { ComparableItem(title: $0.task, status: $0.status) })
        return MeetingChanges(currentMeeting: comparable[0], previousMeeting: comparable[1],
                              items: items)
    }

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
        let explicitlyOpen = ["未完成", "未关闭", "未解决", "待解决", "待完成",
                              "处理中", "进行中", "未开始", "not done", "not closed",
                              "unresolved", "open", "pending"]
        if explicitlyOpen.contains(where: { normalized.contains($0) }) { return false }
        return ["已完成", "完成", "已关闭", "关闭", "已闭环", "已解决", "closed", "done", "resolved"]
            .contains { normalized.contains($0) }
    }

    private struct ComparableItem {
        let title: String
        let status: String
    }

    private static func compare(category: String, current: [ComparableItem],
                                previous: [ComparableItem]) -> [MeetingChanges.Item] {
        let previousByID = Dictionary(previous.map { (identity($0.title), $0) },
                                      uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(current.map { identity($0.title) })
        var result: [MeetingChanges.Item] = current.compactMap { item in
            let key = identity(item.title)
            guard !key.isEmpty else { return nil }
            guard let old = previousByID[key] else {
                return change(category: category, key: key, kind: .new,
                              title: item.title, old: "", new: item.status)
            }
            let kind: MeetingChanges.Kind
            if isClosed(status: item.status) && !isClosed(status: old.status) {
                kind = .closed
            } else if normalizedStatus(item.status) != normalizedStatus(old.status) {
                kind = .statusChanged
            } else if !isClosed(status: item.status) {
                kind = .ongoing
            } else {
                return nil
            }
            return change(category: category, key: key, kind: kind,
                          title: item.title, old: old.status, new: item.status)
        }

        result += previous.compactMap { item in
            let key = identity(item.title)
            guard !key.isEmpty, !currentIDs.contains(key), !isClosed(status: item.status) else {
                return nil
            }
            return change(category: category, key: key, kind: .notMentioned,
                          title: item.title, old: item.status, new: "")
        }
        return result
    }

    private static func change(category: String, key: String, kind: MeetingChanges.Kind,
                               title: String, old: String, new: String) -> MeetingChanges.Item {
        MeetingChanges.Item(id: "\(category)-\(kind.rawValue)-\(key)", kind: kind,
                            category: category, title: title,
                            previousStatus: old, currentStatus: new)
    }

    private static func normalizedStatus(_ status: String) -> String {
        identity(status)
    }

    private static func identity(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(String.init).joined()
    }
}
