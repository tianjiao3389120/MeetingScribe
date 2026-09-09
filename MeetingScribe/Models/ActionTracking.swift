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
        guard let workspaceID else { return "" }
        let ledgerActions = (try? ProjectLedgerStore.load().actions(for: workspaceID)) ?? []
        let rows: String
        if !ledgerActions.isEmpty {
            rows = ledgerActions.filter { !$0.isClosed }.prefix(50).map {
                "- [\($0.id)] \($0.task)；责任方：\($0.owner.isEmpty ? "待明确" : $0.owner)；当前状态：\($0.status.isEmpty ? "待确认" : $0.status)；截止：\($0.due.isEmpty ? "待明确" : $0.due)"
            }.joined(separator: "\n")
        } else {
            guard let records = try? MeetingHistoryStore.loadAll() else { return "" }
            rows = currentOpenActions(in: records.filter { $0.workspaceID == workspaceID }).prefix(50).map {
                "- [\($0.actionID)] \($0.action.task)；责任方：\($0.action.owner.isEmpty ? "待明确" : $0.action.owner)；当前状态：\($0.action.status.isEmpty ? "待确认" : $0.action.status)"
            }.joined(separator: "\n")
        }
        guard !rows.isEmpty else { return "" }
        return """
        项目行动项台账中当前未完成事项如下：
        \(rows)
        若本次会议明确更新了其中某项，必须在 actionItems 中再次输出，并把方括号中的 ID 原样填写到该项独立的 `trackingID` 字段；`task` 只写可执行任务，严禁包含 `[MS-...]` 或任何内部 ID。填写本次明确状态和证据时间码；未提及的事项不要推断状态，不要输出。
        """
    }

    /// Models occasionally copy the private ledger identifier into `task`
    /// despite the schema. Recover it into the structured field and guarantee
    /// that internal IDs never reach rendered minutes or task matching.
    static func normalizeModelOutput(_ structured: inout StructuredMinutes) {
        let pattern = #"\[\s*(MS-[A-Za-z0-9-]+)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        var normalized: [StructuredMinutes.ActionItem] = []
        for var action in structured.actionItems {
            if action.trackingID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                action.trackingID = nil
            }
            let original = action.task
            let range = NSRange(original.startIndex..., in: original)
            let matches = regex.matches(in: original, range: range)
            if action.trackingID == nil, let match = matches.first,
               match.numberOfRanges > 1,
               let idRange = Range(match.range(at: 1), in: original) {
                action.trackingID = String(original[idRange])
            }
            action.task = regex.stringByReplacingMatches(
                in: original, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // An ID without an actual task is not a usable action item.
            if !action.task.isEmpty { normalized.append(action) }
        }
        structured.actionItems = normalized
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
