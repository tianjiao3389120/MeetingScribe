import Foundation

struct IssueAssociationService {
    struct Output: Decodable {
        struct Match: Decodable {
            let issueIndex: Int
            let trackingID: String?
            let reopen: Bool?
            let reason: String?
            let updatedSummary: String?
            let aliases: [String]?
            let searchTerms: [String]?
            let negativeTerms: [String]?
        }
        let matches: [Match]
    }

    struct Result {
        let minutes: StructuredMinutes
        let phase: GenerationUsage.Phase
        let reviewReasons: [String]
    }

    let settings: Settings

    func associate(_ minutes: StructuredMinutes, workspaceID: UUID?) async throws -> Result {
        guard let workspaceID, !minutes.issues.isEmpty else {
            return Result(minutes: minutes, phase: .init(name: "问题关联", inputTokens: 0,
                                                         outputTokens: 0, calls: 0), reviewReasons: [])
        }
        let ledger = (try? ProjectLedgerStore.load()) ?? ProjectLedger()
        let history = ledger.issues(for: workspaceID)
        guard !history.isEmpty else {
            return Result(minutes: minutes, phase: .init(name: "问题关联", inputTokens: 0,
                                                         outputTokens: 0, calls: 0), reviewReasons: [])
        }
        let profilePairs: [(String, String)] = ledger.issueAnalyses.compactMap { analysis in
            guard let issue = history.first(where: { $0.id == analysis.issueID }),
                  !analysis.isStale(comparedWith: issue),
                  let summary = analysis.summary else { return nil }
            return (analysis.issueID, summary)
        }
        let profiles: [String: String] = Dictionary(uniqueKeysWithValues: profilePairs)
        let selection = IssueTracking.associationCandidates(
            for: minutes.issues, from: history, profilesByIssueID: profiles)
        guard !selection.candidates.isEmpty else {
            return Result(minutes: minutes, phase: .init(name: "问题关联", inputTokens: 0,
                                                         outputTokens: 0, calls: 0), reviewReasons: [])
        }
        let debug = PipelineDebugRegistry.active
        debug?.issueSelection("""
        关联阶段：纪要生成后独立执行
        本次问题：\(minutes.issues.count)
        历史问题：\(history.count)
        候选并集：\(selection.candidates.count)
        BM25 短查询排名：
        \(selection.rankingLines.joined(separator: "\n"))
        """)
        let candidates = selection.candidates.map { issue in
            let profile = ledger.analysis(for: issue.id).flatMap { analysis in
                analysis.isStale(comparedWith: issue) ? nil : analysis.summary
            }
            return Self.compactCandidate(issue, rollingProfile: profile)
        }.joined(separator: "\n")
        debug?.issueSelection("模型候选上下文：\(candidates.count) 字符（BM25 本地召回仍使用完整档案）")
        let current = minutes.issues.enumerated().map { index, issue in
            """
            \(index). \(issue.title)
               背景：\(issue.background ?? "")
               根因：\(issue.rootCause)
               方案：\(issue.solution)
               本次进展：\(issue.progress)
               证据：\(issue.evidence.joined(separator: "、"))
            """
        }.joined(separator: "\n")
        let system = """
        你负责把本次会议中已经独立生成的问题，与同一项目的历史问题做严格关联。
        不得改写纪要内容。只有明确属于同一问题时才填写历史 trackingID，否则为 null。
        已闭环问题只有在本次证据明确表明同一问题再次发生时才可关联，并令 reopen=true。
        标题相似但对象、原因或处置不同，不得关联。只输出 JSON。
        每项同时生成 updatedSummary：若关联历史问题，以其最新综合档案为基础，仅用本次问题中的新事实更新；
        若是新问题，则根据本次问题建立首版综合档案。保留仍有效的背景、根因、方案、当前状态、未决事项和下一步，
        不得把推测升级为事实，不得逐场复述，控制在 180–300 字。不要在摘要中输出时间码。
        每项还要更新隐藏检索画像：aliases 是同一对象的真实简称或旧称；searchTerms 是区分度高的产品、对象、
        现象、环境、根因线索和处置动作；negativeTerms 是容易误匹配、但明确代表其他问题的词。
        aliases 最多 3 项，searchTerms 最多 8 项，negativeTerms 最多 4 项。保留历史画像中仍有效的高区分度词，
        去掉“问题、客户、日志、服务器、Agent”等缺乏区分度的通用词，不得臆造名称。
        """
        let user = """
        本次问题（issueIndex 为下面的数字）：
        \(current)

        历史候选：
        \(candidates)

        输出格式：{"matches":[{"issueIndex":0,"trackingID":"MS-ISSUE-...或null","reopen":false,"reason":"简短依据","updatedSummary":"更新后的问题综合档案","aliases":["真实别名"],"searchTerms":["核心检索词"],"negativeTerms":["排除词"]}]}
        每个本次问题必须输出一项。trackingID 只能从历史候选中选择。
        """
        try await debug?.beginNode("问题关联", input: "系统提示词：\n\(system)\n\n用户输入：\n\(user)")
        let raw: String
        do {
            debug?.progress("问题关联", "正在判断本次问题与历史问题的关系…")
            raw = try await ModelTextClient(settings: settings).complete(system: system, user: user)
            debug?.endNode("问题关联", output: raw)
        } catch {
            debug?.endNode("问题关联", output: "失败：\(error.localizedDescription)")
            throw error
        }
        guard let output = Self.parse(raw) else { throw Failure.invalidResponse }
        var updated = minutes
        let allowed: [String: ProjectIssue] = Dictionary(
            uniqueKeysWithValues: selection.candidates.map { ($0.id, $0) })
        let matchesByIndex = Dictionary(output.matches.map { ($0.issueIndex, $0) },
                                        uniquingKeysWith: { first, _ in first })
        var reviewReasons: [String] = []
        for index in updated.issues.indices {
            guard let match = matchesByIndex[index] else {
                reviewReasons.append("“\(updated.issues[index].title)”未返回关联判断")
                continue
            }
            updated.issues[index].rollingSummary = Self.cleanSummary(match.updatedSummary)
            updated.issues[index].proposedAliases = Self.cleanTerms(match.aliases, limit: 3)
            updated.issues[index].proposedSearchTerms = Self.cleanTerms(match.searchTerms, limit: 8)
            updated.issues[index].proposedNegativeTerms = Self.cleanTerms(match.negativeTerms, limit: 4)
            let ranked = selection.rankedByIssue.indices.contains(index)
                ? selection.rankedByIssue[index] : []
            guard let id = match.trackingID else {
                if let exact = ranked.first(where: {
                    !$0.issue.isClosed && $0.reason == "标题/别名命中"
                }) {
                    reviewReasons.append("“\(updated.issues[index].title)”精确命中历史问题“\(exact.issue.title)”但被判为新问题")
                }
                continue
            }
            guard let historical = allowed[id] else {
                reviewReasons.append("“\(updated.issues[index].title)”返回了候选范围外的关联")
                continue
            }
            if historical.isClosed {
                guard match.reopen == true else {
                    reviewReasons.append("“\(updated.issues[index].title)”关联已闭环问题但未确认复发")
                    continue
                }
                updated.issues[index].trackingID = id
                reviewReasons.append("“\(updated.issues[index].title)”将重新打开已闭环问题“\(historical.title)”")
                continue
            }
            updated.issues[index].trackingID = id
            let openRanked = ranked.filter { !$0.issue.isClosed }
            let first = openRanked.first
            let secondScore = openRanked.dropFirst().first?.score ?? 0
            let highConfidence = first?.issue.id == id && (first?.score ?? 0) >= 20
                && (secondScore == 0 || (first?.score ?? 0) >= secondScore * 1.35)
            if !highConfidence {
                reviewReasons.append("“\(updated.issues[index].title)”的历史候选分数接近或模型未选择首位")
            }
        }
        return Result(minutes: updated,
                      phase: GenerationUsage.estimatedPhase(
                        name: "问题关联", input: system + "\n" + user, output: raw),
                      reviewReasons: reviewReasons)
    }

    static func parse(_ raw: String) -> Output? {
        guard let first = raw.firstIndex(of: "{"), let last = raw.lastIndex(of: "}") else { return nil }
        return try? JSONDecoder().decode(Output.self, from: Data(raw[first...last].utf8))
    }

    private static func cleanSummary(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.replacingOccurrences(
            of: #"\s*[（(]?\[\d{1,2}:\d{2}(?::\d{2})?\][）)]?"#,
            with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(1800))
    }

    private static func cleanTerms(_ values: [String]?, limit: Int) -> [String]? {
        guard let values else { return nil }
        var seen = Set<String>()
        let cleaned = values.compactMap { value -> String? in
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = term.lowercased()
            guard term.count >= 2, term.count <= 50, seen.insert(key).inserted else { return nil }
            return term
        }
        return Array(cleaned.prefix(limit))
    }

    static func compactCandidate(_ issue: ProjectIssue, rollingProfile: String?) -> String {
        let profile = rollingProfile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let aliases = issue.aliases.prefix(4).joined(separator: "、")
        let search = (issue.searchTerms ?? []).prefix(10).joined(separator: "、")
        let negative = (issue.negativeTerms ?? []).prefix(6).joined(separator: "、")
        let details: String
        if !profile.isEmpty {
            details = "综合档案摘要：\(compact(profile, limit: 360))"
        } else {
            let latest = issue.events.sorted { $0.occurredAt > $1.occurredAt }.first?.progress ?? ""
            details = "背景：\(compact(issue.background, limit: 120))\n  根因：\(compact(issue.rootCause, limit: 120))\n  方案：\(compact(issue.solution, limit: 120))\n  最近进展：\(compact(latest, limit: 100))"
        }
        return """
        - [\(issue.id)] \(issue.isClosed ? "已闭环" : issue.status)｜\(issue.title)
          别名：\(aliases.isEmpty ? "无" : aliases)
          检索词：\(search.isEmpty ? "无" : search)
          排除词：\(negative.isEmpty ? "无" : negative)
          \(details)
        """
    }

    private static func compact(_ value: String, limit: Int) -> String {
        let cleaned = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "未记录" }
        return cleaned.count <= limit ? cleaned : String(cleaned.prefix(limit)) + "…"
    }

    enum Failure: LocalizedError {
        case invalidResponse
        var errorDescription: String? { "问题关联模型没有返回可解析的 JSON。" }
    }
}
