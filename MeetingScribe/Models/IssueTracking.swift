import Foundation

enum IssueTracking {
    static func prepare(_ structured: inout StructuredMinutes,
                        confirmedIssues: [ProjectIssue]) {
        let candidates = confirmedIssues.map {
            TrackedIssue(id: $0.id, title: $0.title, background: $0.background,
                         rootCause: $0.rootCause, solution: $0.solution,
                         status: $0.status, updatedAt: $0.updatedAt)
        }
        for index in structured.issues.indices {
            if structured.issues[index].trackingID?.trimmed.isEmpty == true {
                structured.issues[index].trackingID = nil
            }
            if let id = structured.issues[index].trackingID,
               candidates.contains(where: { $0.id == id }) { continue }
            if let match = bestMatch(for: structured.issues[index], among: candidates) {
                structured.issues[index].trackingID = match.id
            } else {
                structured.issues[index].trackingID = "MS-ISSUE-\(UUID().uuidString.uppercased())"
            }
        }
        let knownIssueIDs = Set(structured.issues.compactMap(\.trackingID))
        let issueIDsByTitle = Dictionary(
            structured.issues.compactMap { issue -> (String, String)? in
                guard let id = issue.trackingID else { return nil }
                return (identity(issue.title), id)
            }, uniquingKeysWith: { first, _ in first })
        for index in structured.actionItems.indices {
            guard let issueID = structured.actionItems[index].issueID else { continue }
            if knownIssueIDs.contains(issueID) { continue }
            // A newly discovered issue has no stable ID while the model is producing JSON.
            // The prompt therefore lets an action temporarily reference its exact title; once
            // IDs are assigned above, resolve that response-local reference deterministically.
            structured.actionItems[index].issueID = issueIDsByTitle[identity(issueID)]
        }
    }

    static func promptContext(for workspaceID: UUID?) -> String {
        guard let workspaceID else { return "" }
        let ledgerIssues = (try? ProjectLedgerStore.load().issues(for: workspaceID)) ?? []
        let openLedger = ledgerIssues.filter { !$0.isClosed }
        // Only human-confirmed issue files may influence a later meeting. Falling back to raw
        // minutes makes a clean chronological rebuild accidentally read unconfirmed or future
        // versions and defeats the review gate.
        let rows = openLedger.map {
            TrackedIssue(id: $0.id, title: $0.title, background: $0.background,
                         rootCause: $0.rootCause, solution: $0.solution,
                         status: $0.status, updatedAt: $0.updatedAt)
        }
        guard !rows.isEmpty else { return "" }
        let text = rows.prefix(30).map { issue in
            """
            - [\(issue.id)] \(issue.title)；当前状态：\(issue.status.isEmpty ? "待确认" : issue.status)
              历史背景：\(compact(issue.background))
              当前根因：\(compact(issue.rootCause))
              当前方案：\(compact(issue.solution))
            """
        }.joined(separator: "\n")
        return """
        同一项目当前未闭环的问题档案如下。这些内容是历史上下文，不代表本次会议重新确认：
        \(text)
        若本次明确讨论其中某个问题，在 issues 中原样填写方括号内 ID。背景可继承必要的稳定信息，progress 只写截至本次会议的新进展；历史推测不得升级为确定结论。未提及的问题不要输出、不要改变状态。若只是相似但无法确认是否同一问题，不要强行关联，trackingID 填 null。
        """
    }

    struct TrackedIssue {
        let id: String
        let title: String
        let background: String
        let rootCause: String
        let solution: String
        let status: String
        let updatedAt: Date
    }

    static func currentIssues(in records: [MeetingRecord]) -> [TrackedIssue] {
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        var seen = Set<String>()
        var result: [TrackedIssue] = []
        for record in sorted {
            for (index, issue) in (record.structuredSummary?.issues ?? []).enumerated() {
                let key = issue.trackingID ?? identity(issue.title)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                result.append(TrackedIssue(
                    id: issue.trackingID ?? "MS-ISSUE-\(record.id.uuidString.uppercased())-\(index + 1)",
                    title: issue.title, background: issue.background ?? "",
                    rootCause: issue.rootCause, solution: issue.solution,
                    status: issue.status, updatedAt: record.createdAt))
            }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func bestMatch(for issue: StructuredMinutes.Issue,
                                  among candidates: [TrackedIssue]) -> TrackedIssue? {
        let ranked = candidates.map { ($0, similarity(issue, $0)) }.sorted { $0.1 > $1.1 }
        guard let first = ranked.first, first.1 >= 0.72,
              ranked.count == 1 || first.1 - ranked[1].1 >= 0.12 else { return nil }
        return first.0
    }

    private static func similarity(_ issue: StructuredMinutes.Issue,
                                   _ candidate: TrackedIssue) -> Double {
        let title = dice(issue.title, candidate.title)
        let details = dice([issue.background ?? "", issue.rootCause, issue.solution].joined(),
                           [candidate.background, candidate.rootCause, candidate.solution].joined())
        return title * 0.7 + details * 0.3
    }

    private static func dice(_ lhs: String, _ rhs: String) -> Double {
        let a = shingles(identity(lhs)), b = shingles(identity(rhs))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return 2 * Double(a.intersection(b).count) / Double(a.count + b.count)
    }

    private static func shingles(_ text: String) -> Set<String> {
        let chars = Array(text)
        guard chars.count > 1 else { return text.isEmpty ? [] : [text] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
    }

    static func identity(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    private static func compact(_ value: String) -> String {
        let trimmed = value.trimmed
        return trimmed.isEmpty ? "未明确" : String(trimmed.prefix(300))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
