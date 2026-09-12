import Foundation

enum IssueTracking {
    static let unfilteredIssueLimit = 12
    static let unfilteredContextCharacterLimit = 4_000
    static let filteredDetailedLimit = 8
    static let lightweightIndexLimit = 40
    static let closedReopenLimit = 3
    static let closedReopenMinimumBM25 = 8.0

    struct CandidateScore {
        let issue: ProjectIssue
        let score: Double
        let reason: String
    }

    struct PromptSelection {
        let context: String
        let totalCount: Int
        let openCount: Int
        let detailedCount: Int
        let indexCount: Int
        let omittedCount: Int
        let originalContextCharacters: Int
        let closedReopenCount: Int
        let rankingLines: [String]
        let strategy: String
        let reasons: [String: Int]

        var debugSummary: String {
            let reasonText = reasons.isEmpty ? "<无需筛选>" : reasons.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: " / ")
            return """
            项目问题：总计 \(totalCount)
            未闭环：\(openCount)
            候选策略：\(strategy)
            详细候选：\(detailedCount)
            轻量索引：\(indexCount)
            超出预算省略：\(omittedCount)
            筛选原因：\(reasonText)
            筛选前问题正文估算：\(originalContextCharacters) 字
            历史上下文：\(context.count) 字
            已闭环复发候选：\(closedReopenCount)
            BM25 排名：
            \(rankingLines.isEmpty ? "<未启用>" : rankingLines.joined(separator: "\n"))
            """
        }
    }

    static func prepare(_ structured: inout StructuredMinutes,
                        confirmedIssues: [ProjectIssue]) {
        let candidates = confirmedIssues.map {
            TrackedIssue(id: $0.id, title: $0.title, background: $0.background,
                         rootCause: $0.rootCause, solution: $0.solution,
                         status: $0.status, updatedAt: $0.updatedAt)
        }
        let openCandidates = zip(confirmedIssues, candidates).compactMap {
            $0.0.isClosed ? nil : $0.1
        }
        for index in structured.issues.indices {
            if structured.issues[index].trackingID?.trimmed.isEmpty == true {
                structured.issues[index].trackingID = nil
            }
            if let id = structured.issues[index].trackingID,
               candidates.contains(where: { $0.id == id }) { continue }
            // A closed issue may only be restored by the explicit post-minutes association
            // stage, which checks for evidence of recurrence. Local fallback stays open-only.
            if let match = bestMatch(for: structured.issues[index], among: openCandidates) {
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

    static func promptSelection(for workspaceID: UUID?, evidenceText: String) -> PromptSelection {
        guard let workspaceID else {
            return PromptSelection(context: "", totalCount: 0, openCount: 0,
                                   detailedCount: 0, indexCount: 0, omittedCount: 0,
                                   originalContextCharacters: 0,
                                   closedReopenCount: 0, rankingLines: [],
                                   strategy: "未关联正式项目", reasons: [:])
        }
        let ledgerIssues = (try? ProjectLedgerStore.load().issues(for: workspaceID)) ?? []
        let openLedger = ledgerIssues.filter { !$0.isClosed }
        let closedLedger = ledgerIssues.filter(\.isClosed)
        // Only human-confirmed issue files may influence a later meeting. Falling back to raw
        // minutes makes a clean chronological rebuild accidentally read unconfirmed or future
        // versions and defeats the review gate.
        let selected = candidateSelection(from: openLedger, evidenceText: evidenceText)
        let closedCandidates = closedReopenCandidates(
            from: closedLedger, evidenceText: evidenceText)
        let rows = selected.detailed.map {
            TrackedIssue(id: $0.id, title: $0.title, background: $0.background,
                         rootCause: $0.rootCause, solution: $0.solution,
                         status: $0.status, updatedAt: $0.updatedAt)
        }
        guard !rows.isEmpty || !closedCandidates.isEmpty else {
            return PromptSelection(context: "", totalCount: ledgerIssues.count,
                                   openCount: 0, detailedCount: 0, indexCount: 0, omittedCount: 0,
                                   originalContextCharacters: 0,
                                   closedReopenCount: 0, rankingLines: [],
                                   strategy: "无未闭环问题", reasons: [:])
        }
        let text = rows.map { issue in
            """
            - [\(issue.id)] \(issue.title)；当前状态：\(issue.status.isEmpty ? "待确认" : issue.status)
              历史背景：\(compact(issue.background))
              当前根因：\(compact(issue.rootCause))
              当前方案：\(compact(issue.solution))
            """
        }.joined(separator: "\n")
        let index = selected.index.map { issue in
            let aliases = issue.aliases.isEmpty ? "" : "；别名：\(issue.aliases.joined(separator: "、"))"
            return "- [\(issue.id)] \(issue.title)；状态：\(issue.status.isEmpty ? "待确认" : issue.status)\(aliases)"
        }.joined(separator: "\n")
        let indexSection = index.isEmpty ? "" : """

        其余可能相关问题的轻量索引如下。只有本次明确讨论时才可关联；索引不提供的历史细节不得自行补充：
        \(index)
        """
        let closedSection = closedCandidates.isEmpty ? "" : """

        以下问题已经闭环，仅用于判断本次是否明确复发。不得继承为当前问题；只有本次证据明确显示同一问题再次发生时，才可返回其 ID 并建议重新打开：
        \(closedCandidates.map { "- [\($0.issue.id)] \($0.issue.title)；状态：已闭环；BM25：\(scoreText($0.score))" }.joined(separator: "\n"))
        """
        let context = """
        同一项目当前未闭环的问题档案如下。这些内容是历史上下文，不代表本次会议重新确认：
        \(text)
        \(indexSection)
        \(closedSection)
        若本次明确讨论其中某个问题，在 issues 中原样填写方括号内 ID。背景可继承必要的稳定信息，progress 只写截至本次会议的新进展；历史推测不得升级为确定结论。未提及的问题不要输出、不要改变状态。若只是相似但无法确认是否同一问题，不要强行关联，trackingID 填 null。
        """
        return PromptSelection(context: context, totalCount: ledgerIssues.count,
                               openCount: openLedger.count, detailedCount: rows.count,
                               indexCount: selected.index.count, omittedCount: selected.omittedCount,
                               originalContextCharacters: openLedger.reduce(0) {
                                   $0 + estimatedDetailedCharacters($1)
                               },
                               closedReopenCount: closedCandidates.count,
                               rankingLines: selected.scores.enumerated().map {
                                   "\($0.offset + 1). \($0.element.issue.title) · BM25 \(scoreText($0.element.score)) · \($0.element.reason)"
                               } + closedCandidates.enumerated().map {
                                   "闭环 \($0.offset + 1). \($0.element.issue.title) · BM25 \(scoreText($0.element.score)) · 复发候选"
                               },
                               strategy: selected.filtered ? "BM25 本地粗筛" : "全部提交",
                               reasons: selected.reasons)
    }

    static func promptContext(for workspaceID: UUID?) -> String {
        promptSelection(for: workspaceID, evidenceText: "").context
    }

    static func candidateSelection(from issues: [ProjectIssue], evidenceText: String)
        -> (detailed: [ProjectIssue], index: [ProjectIssue], omittedCount: Int,
            filtered: Bool, reasons: [String: Int], scores: [CandidateScore]) {
        let fullContextCharacters = issues.reduce(0) { $0 + estimatedDetailedCharacters($1) }
        let staysUnfiltered = issues.count <= unfilteredIssueLimit
            && fullContextCharacters <= unfilteredContextCharacterLimit
        guard !staysUnfiltered else { return (issues, [], 0, false, [:], []) }
        let ranked = rankedIssues(issues, evidenceText: evidenceText)

        var detailed: [ProjectIssue] = []
        var reasons: [String: Int] = [:]
        var scores: [CandidateScore] = []
        for candidate in ranked.prefix(6) {
            detailed.append(candidate.issue)
            scores.append(candidate)
            reasons[candidate.reason, default: 0] += 1
        }
        for issue in issues.sorted(by: { $0.updatedAt > $1.updatedAt })
            where detailed.count < filteredDetailedLimit && !detailed.contains(where: { $0.id == issue.id }) {
            detailed.append(issue)
            let score = ranked.first(where: { $0.issue.id == issue.id })?.score ?? 0
            scores.append(CandidateScore(issue: issue, score: score, reason: "最近补足"))
            reasons["最近补足", default: 0] += 1
        }
        let selectedIDs = Set(detailed.map(\.id))
        let remaining = ranked.map(\.issue).filter { !selectedIDs.contains($0.id) }
        let index = Array(remaining.prefix(lightweightIndexLimit))
        return (detailed, index, max(remaining.count - index.count, 0), true, reasons, scores)
    }

    static func closedReopenCandidates(from issues: [ProjectIssue],
                                       evidenceText: String) -> [CandidateScore] {
        Array(rankedIssues(issues, evidenceText: evidenceText)
            .filter { $0.reason == "标题/别名命中" || $0.score >= closedReopenMinimumBM25 }
            .prefix(closedReopenLimit))
    }

    struct AssociationSelection {
        let candidates: [ProjectIssue]
        let rankingLines: [String]
        let rankedByIssue: [[CandidateScore]]
    }

    /// Retrieves against concise, model-produced issue descriptions instead of the entire
    /// transcript. This prevents frequent meeting vocabulary from overwhelming BM25.
    static func associationCandidates(for currentIssues: [StructuredMinutes.Issue],
                                      from historicalIssues: [ProjectIssue],
                                      profilesByIssueID: [String: String] = [:]) -> AssociationSelection {
        var chosen: [String: CandidateScore] = [:]
        var lines: [String] = []
        var rankedByIssue: [[CandidateScore]] = []
        for (offset, current) in currentIssues.enumerated() {
            let query = [current.title, current.background ?? "", current.rootCause,
                         current.solution, current.progress].joined(separator: "\n")
            let open = rankedIssues(historicalIssues.filter { !$0.isClosed }, evidenceText: query,
                                    profilesByIssueID: profilesByIssueID)
            let closed = rankedIssues(historicalIssues.filter(\.isClosed), evidenceText: query,
                                      profilesByIssueID: profilesByIssueID)
                .filter { $0.reason == "标题/别名命中" || $0.score >= closedReopenMinimumBM25 }
            let selectedOpen = Array(open.prefix(2))
            let selectedClosed = Array(closed.prefix(1))
            rankedByIssue.append(selectedOpen + selectedClosed)
            for candidate in selectedOpen + selectedClosed {
                if candidate.score > (chosen[candidate.issue.id]?.score ?? -.infinity) {
                    chosen[candidate.issue.id] = candidate
                }
            }
            let rank = (selectedOpen.map { "未闭环 \($0.issue.title) · \(scoreText($0.score))" }
                + selectedClosed.map { "已闭环复发 \($0.issue.title) · \(scoreText($0.score))" })
                .joined(separator: "；")
            lines.append("本次问题 \(offset + 1)《\(current.title)》：\(rank.isEmpty ? "<无候选>" : rank)")
        }
        let ordered = chosen.values.sorted {
            $0.score == $1.score ? $0.issue.updatedAt > $1.issue.updatedAt : $0.score > $1.score
        }
        return AssociationSelection(candidates: Array(ordered.prefix(18).map(\.issue)),
                                    rankingLines: lines, rankedByIssue: rankedByIssue)
    }

    private static func rankedIssues(_ issues: [ProjectIssue],
                                     evidenceText: String,
                                     profilesByIssueID: [String: String] = [:]) -> [CandidateScore] {
        guard !issues.isEmpty else { return [] }
        let queryTerms = Set(searchTerms(evidenceText))
        let normalizedEvidence = normalized(evidenceText)
        let documents = issues.map {
            weightedTerms(for: $0, rollingProfile: profilesByIssueID[$0.id])
        }
        let averageLength = max(Double(documents.reduce(0) {
            $0 + $1.values.reduce(0, +)
        }) / Double(max(documents.count, 1)), 1)
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for term in document.keys where queryTerms.contains(term) {
                documentFrequency[term, default: 0] += 1
            }
        }
        return zip(issues, documents).map { issue, document -> CandidateScore in
            let title = normalized(issue.title)
            let aliasValues = issue.aliases.map(normalized).filter { !$0.isEmpty }
            let exactTitle = !title.isEmpty && normalizedEvidence.contains(title)
            let exactAlias = aliasValues.contains { normalizedEvidence.contains($0) }
            let bm25 = bm25Score(document: document, queryTerms: queryTerms,
                                  documentFrequency: documentFrequency,
                                  documentCount: documents.count,
                                  averageDocumentLength: averageLength)
            let negativeHits = (issue.negativeTerms ?? []).filter {
                let term = normalized($0)
                return !term.isEmpty && normalizedEvidence.contains(term)
            }.count
            let negativePenalty = Double(min(negativeHits, 2) * 12)
            let score = bm25 + (exactTitle ? 20 : 0) + (exactAlias ? 15 : 0)
                - negativePenalty
            let reason = exactTitle || exactAlias ? "标题/别名命中"
                : (negativeHits > 0 ? "排除词冲突" : (bm25 > 0 ? "BM25匹配" : "弱相关"))
            return CandidateScore(issue: issue, score: score, reason: reason)
        }.sorted { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.issue.updatedAt > rhs.issue.updatedAt
                : lhs.score > rhs.score
        }
    }

    private static func scoreText(_ score: Double) -> String {
        String(format: "%.2f", score)
    }

    private static func estimatedDetailedCharacters(_ issue: ProjectIssue) -> Int {
        issue.id.count + issue.title.count + issue.status.count
            + min(issue.background.count, 300)
            + min(issue.rootCause.count, 300)
            + min(issue.solution.count, 300) + 45
    }

    private static func weightedTerms(for issue: ProjectIssue,
                                      rollingProfile: String? = nil) -> [String: Int] {
        var frequencies: [String: Int] = [:]
        func add(_ text: String, weight: Int) {
            for term in searchTerms(text) { frequencies[term, default: 0] += weight }
        }
        add(issue.title, weight: 4)
        for alias in issue.aliases { add(alias, weight: 3) }
        for term in issue.searchTerms ?? [] { add(term, weight: 3) }
        add(issue.background, weight: 1)
        add(issue.rootCause, weight: 1)
        add(issue.solution, weight: 1)
        if let rollingProfile { add(rollingProfile, weight: 2) }
        return frequencies
    }

    private static func bm25Score(document: [String: Int], queryTerms: Set<String>,
                                  documentFrequency: [String: Int], documentCount: Int,
                                  averageDocumentLength: Double) -> Double {
        let length = Double(document.values.reduce(0, +))
        let k1 = 1.2, b = 0.75
        return document.reduce(into: 0.0) { score, entry in
            guard queryTerms.contains(entry.key) else { return }
            let frequency = Double(entry.value)
            let containing = Double(documentFrequency[entry.key] ?? 0)
            let idf = log(1 + (Double(documentCount) - containing + 0.5) / (containing + 0.5))
            let denominator = frequency + k1 * (1 - b + b * length / averageDocumentLength)
            score += idf * frequency * (k1 + 1) / denominator
        }
    }

    private static func searchTerms(_ text: String) -> [String] {
        let value = normalized(text)
        guard !value.isEmpty else { return [] }
        let chars = Array(value)
        var terms: [String] = []
        if chars.count == 1 { terms.append(value) }
        if chars.count >= 2 {
            terms.append(contentsOf: (0...(chars.count - 2)).map { String(chars[$0...($0 + 1)]) })
        }
        if chars.count >= 3 {
            terms.append(contentsOf: (0...(chars.count - 3)).map { String(chars[$0...($0 + 2)]) })
        }
        let asciiWords = text.lowercased().split { character in
            !character.unicodeScalars.allSatisfy {
                $0.isASCII && CharacterSet.alphanumerics.contains($0)
            }
        }.map(String.init).filter { $0.count >= 2 }
        terms.append(contentsOf: asciiWords)
        return terms
    }

    private static func normalized(_ text: String) -> String {
        identity(text)
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
