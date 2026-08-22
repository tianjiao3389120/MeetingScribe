import Foundation

struct HistoricalActionReviewService {
    struct Result: Sendable {
        let reviewedMeetings: Int
        let suggestions: Int
        let updatedRecords: [MeetingRecord]
    }

    private struct ProposedUpdate: Codable {
        let targetActionID: String
        let proposedStatus: String
        let evidence: [String]
    }

    private struct Response: Codable {
        let updates: [ProposedUpdate]
    }

    let settings: Settings

    func run(records sourceRecords: [MeetingRecord], workspaceID: UUID,
             progress: @escaping @Sendable (String) -> Void) async throws -> Result {
        let records = sourceRecords.filter { $0.workspaceID == workspaceID }
            .sorted { $0.createdAt < $1.createdAt }
        guard records.count > 1 else {
            return Result(reviewedMeetings: 0, suggestions: 0, updatedRecords: [])
        }

        // Construct once so API-backed runs read their key at most once.
        let client = try ModelTextClient(settings: settings)
        var working = records
        var changed: [MeetingRecord] = []
        var reviewed = 0
        var suggestionCount = 0

        for index in working.indices where index > 0 {
            let prior = Array(working[..<index])
            let open = ActionTracking.currentOpenActions(in: prior)
            guard !open.isEmpty else { continue }
            reviewed += 1
            progress("正在回溯第 \(index + 1)/\(working.count) 场会议…")
            let raw = try await client.complete(
                system: Self.systemPrompt,
                user: Self.userPrompt(meeting: working[index], openActions: open))
            let proposed = Self.parse(raw)
            let additions = Self.validatedSuggestions(proposed, openActions: open)
            guard !additions.isEmpty else { continue }

            let applied = Set(working[index].appliedActionSuggestionIDs ?? [])
            var merged = (working[index].actionStatusSuggestions ?? [])
                .filter { existing in
                    applied.contains(existing.id)
                        || !additions.contains(where: { Self.same(existing, $0) })
                }
            merged.append(contentsOf: additions)
            let updated = try MeetingHistoryStore.updateActionSuggestions(
                id: working[index].id, suggestions: merged)
            working[index] = updated
            changed.append(updated)
            suggestionCount += additions.count
        }
        return Result(reviewedMeetings: reviewed, suggestions: suggestionCount,
                      updatedRecords: changed)
    }

    private static let systemPrompt = """
    你负责核对历史会议中的待办状态。用户会提供此前仍未完成的待办和一场后续会议逐字稿。
    只有后续会议明确提到某项待办，并明确说明其状态发生变化时才输出更新。
    不得因未提及、话题消失或时间已经过去而推断完成。不要用常识补全，不要创建新待办。
    evidence 必须填写逐字稿中支持判断的原始时间码；没有时间码或证据不充分就不要输出。
    只输出合法 JSON：{"updates":[{"targetActionID":"原待办ID","proposedStatus":"新状态","evidence":["[12:34]"]}]}
    """

    private static func userPrompt(meeting: MeetingRecord,
                                   openActions: [ActionTracking.TrackedAction]) -> String {
        let actions = openActions.prefix(50).map {
            "- [\($0.actionID)] \($0.action.task)；责任方：\($0.action.owner.isEmpty ? "待明确" : $0.action.owner)；原状态：\($0.action.status.isEmpty ? "待确认" : $0.action.status)"
        }.joined(separator: "\n")
        let transcript = String(meeting.transcript.timecodedText.prefix(45_000))
        return """
        后续会议：\(meeting.title)
        日期：\(meeting.createdAt.formatted(date: .numeric, time: .omitted))

        此前未完成待办：
        \(actions)

        后续会议逐字稿：
        \(transcript)
        """
    }

    private static func parse(_ raw: String) -> [ProposedUpdate] {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = candidate.firstIndex(of: "{"), let last = candidate.lastIndex(of: "}") {
            candidate = String(candidate[first...last])
        }
        guard let data = candidate.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return response.updates
    }

    private static func validatedSuggestions(
        _ updates: [ProposedUpdate], openActions: [ActionTracking.TrackedAction]
    ) -> [ActionStatusSuggestion] {
        updates.compactMap { update in
            guard let target = openActions.first(where: { $0.actionID == update.targetActionID }),
                  !update.proposedStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ActionTracking.statusIdentity(update.proposedStatus)
                    != ActionTracking.statusIdentity(target.action.status),
                  !update.evidence.isEmpty,
                  update.evidence.allSatisfy({ $0.contains(":") }) else { return nil }
            return ActionStatusSuggestion(
                targetMeetingID: target.meetingID, targetActionID: target.actionID,
                task: target.action.task, previousStatus: target.action.status,
                proposedStatus: update.proposedStatus, evidence: update.evidence)
        }
    }

    private static func same(_ lhs: ActionStatusSuggestion,
                             _ rhs: ActionStatusSuggestion) -> Bool {
        lhs.targetActionID == rhs.targetActionID
            && ActionTracking.statusIdentity(lhs.proposedStatus)
                == ActionTracking.statusIdentity(rhs.proposedStatus)
            && lhs.evidence == rhs.evidence
    }
}
