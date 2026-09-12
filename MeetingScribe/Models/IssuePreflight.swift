import Foundation

enum IssuePreflight {
    static func automaticDecisionDescription(
        for issue: StructuredMinutes.Issue,
        historicalIssues: [ProjectIssue]
    ) -> String {
        guard let trackingID = issue.trackingID,
              let historical = historicalIssues.first(where: { $0.id == trackingID }) else {
            return "新建项目问题"
        }
        return "合并到历史问题「\(historical.title)」并记录本次进展"
    }

    static func reviewIndices(in issues: [StructuredMinutes.Issue], reasons: [String]) -> Set<Int> {
        guard !issues.isEmpty else { return [] }
        // An empty reason list means the user explicitly enabled "always review".
        guard !reasons.isEmpty else { return Set(issues.indices) }
        let matched = Set(issues.indices.filter { index in
            reasons.contains { $0.contains("“\(issues[index].title)”") }
        })
        // Generic failures (for example an unavailable association model) cannot be assigned
        // safely to one row, so retain the conservative whole-list review.
        return matched.isEmpty ? Set(issues.indices) : matched
    }

    static func risks(in issues: [StructuredMinutes.Issue]) -> [String] {
        guard issues.count > 1 else { return [] }
        var result: [String] = []
        let subordinateTerms = ["日志不足", "证据不足", "无法定位", "排查困难", "缺少日志",
                                "缺少证据", "验证环境", "待补充日志", "信息不足"]
        for issue in issues where subordinateTerms.contains(where: { issue.title.contains($0) }) {
            result.append("“\(issue.title)”可能是其他问题的排查限制，而非独立问题")
        }
        for left in issues.indices {
            for right in issues.indices where right > left {
                let a = tokens(issues[left]), b = tokens(issues[right])
                guard !a.isEmpty, !b.isEmpty else { continue }
                let overlap = Double(a.intersection(b).count) / Double(min(a.count, b.count))
                if overlap >= 0.42 {
                    result.append("“\(issues[left].title)”与“\(issues[right].title)”内容重叠较高")
                }
            }
        }
        return Array(Set(result)).sorted()
    }

    static func merge(_ source: StructuredMinutes.Issue,
                      into target: StructuredMinutes.Issue) -> StructuredMinutes.Issue {
        var merged = target
        merged.background = join(target.background, source.background)
        merged.rootCause = join(target.rootCause, source.rootCause)
        merged.solution = join(target.solution, source.solution)
        merged.progress = join(target.progress, source.progress)
        merged.evidence = Array(Set(target.evidence + source.evidence)).sorted()
        clearProposedProfile(in: &merged)
        return merged
    }

    static func setHistoricalAssociation(_ trackingID: String?,
                                         on issue: inout StructuredMinutes.Issue) {
        guard issue.trackingID != trackingID else { return }
        issue.trackingID = trackingID
        clearProposedProfile(in: &issue)
    }

    static func clearProposedProfile(in issue: inout StructuredMinutes.Issue) {
        issue.rollingSummary = nil
        issue.proposedAliases = nil
        issue.proposedSearchTerms = nil
        issue.proposedNegativeTerms = nil
    }

    private static func join(_ lhs: String?, _ rhs: String?) -> String? {
        let values = [lhs, rhs].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : Array(NSOrderedSet(array: values))
            .compactMap { $0 as? String }.joined(separator: "；")
    }

    private static func join(_ lhs: String, _ rhs: String) -> String {
        join(Optional(lhs), Optional(rhs)) ?? ""
    }

    private static func tokens(_ issue: StructuredMinutes.Issue) -> Set<String> {
        let text = [issue.title, issue.background ?? "", issue.rootCause, issue.solution]
            .joined().lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let chars = Array(text)
        guard chars.count > 1 else { return [] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
    }
}
