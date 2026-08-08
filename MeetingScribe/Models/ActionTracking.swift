import Foundation

enum ActionTracking {
    struct TrackedAction {
        let meetingID: UUID
        let actionID: String
        let action: StructuredMinutes.ActionItem
    }

    static func prepare(_ structured: inout StructuredMinutes,
                        priorRecords: [MeetingRecord]) -> [ActionStatusSuggestion] {
        let open = currentOpenActions(in: priorRecords)
        var suggestions: [ActionStatusSuggestion] = []
        for index in structured.actionItems.indices {
            let action = structured.actionItems[index]
            if let match = open.first(where: { identity($0.action.task) == identity(action.task) }) {
                structured.actionItems[index].trackingID = match.actionID
                let old = statusIdentity(match.action.status)
                let new = statusIdentity(action.status)
                if !new.isEmpty, new != old, !action.evidence.isEmpty {
                    suggestions.append(ActionStatusSuggestion(
                        targetMeetingID: match.meetingID, targetActionID: match.actionID,
                        task: match.action.task, previousStatus: match.action.status,
                        proposedStatus: action.status, evidence: action.evidence))
                }
            } else if structured.actionItems[index].trackingID == nil {
                structured.actionItems[index].trackingID = "MS-\(UUID().uuidString.uppercased())"
            }
        }
        return suggestions
    }

    static func currentOpenActions(in records: [MeetingRecord]) -> [TrackedAction] {
        var seenTasks = Set<String>()
        var seenIDs = Set<String>()
        var result: [TrackedAction] = []
        for record in records.sorted(by: { $0.createdAt > $1.createdAt }) {
            for (index, action) in (record.structuredSummary?.actionItems ?? []).enumerated() {
                let actionID = id(for: action, meetingID: record.id, index: index)
                let taskKey = identity(action.task)
                guard !taskKey.isEmpty,
                      !seenTasks.contains(taskKey), !seenIDs.contains(actionID) else { continue }
                seenTasks.insert(taskKey); seenIDs.insert(actionID)
                guard !action.isClosed else { continue }
                result.append(TrackedAction(meetingID: record.id, actionID: actionID, action: action))
            }
        }
        return result
    }

    static func promptContext(for workspaceID: UUID?) -> String {
        guard let workspaceID,
              let records = try? MeetingHistoryStore.loadAll() else { return "" }
        let actions = currentOpenActions(in: records.filter { $0.workspaceID == workspaceID })
        guard !actions.isEmpty else { return "" }
        let rows = actions.prefix(50).map {
            "- [\($0.actionID)] \($0.action.task)；责任方：\($0.action.owner.isEmpty ? "待明确" : $0.action.owner)；当前状态：\($0.action.status.isEmpty ? "待确认" : $0.action.status)"
        }.joined(separator: "\n")
        return """
        历史未完成待办如下：
        \(rows)
        若本次会议明确更新了其中某项，必须在 actionItems 中再次输出，task 尽量保持原文，填写本次明确状态和证据时间码；未提及的事项不要推断状态，不要输出。
        """
    }

    static func id(for action: StructuredMinutes.ActionItem,
                   meetingID: UUID, index: Int) -> String {
        action.trackingID ?? "MS-\(meetingID.uuidString.uppercased())-\(index + 1)"
    }

    static func identity(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static func statusIdentity(_ value: String) -> String {
        identity(value)
    }
}
