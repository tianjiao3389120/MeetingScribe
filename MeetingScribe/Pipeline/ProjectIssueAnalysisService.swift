import Foundation

struct ProjectIssueAnalysisService {
    struct Report: Sendable, Equatable {
        struct TimelineItem: Sendable, Equatable {
            let date: String
            let meetingTitle: String
            let change: String
        }
        let summary: String
        let timeline: [TimelineItem]
    }

    private struct Response: Codable {
        struct TimelineItem: Codable {
            let date: String
            let meetingTitle: String
            let change: String
        }
        let summary: String
        let timeline: [TimelineItem]
    }

    let settings: Settings

    static func estimatedTokens(issue: ProjectIssue, records: [MeetingRecord]) -> Int {
        TokenEstimator.count(systemPrompt + "\n" + sourceMaterial(issue: issue, records: records)) + 900
    }

    func analyze(issue: ProjectIssue, records: [MeetingRecord]) async throws -> Report {
        let material = Self.sourceMaterial(issue: issue, records: records)
        let raw = try await ModelTextClient(settings: settings).complete(
            system: Self.systemPrompt, user: material,
            promptID: "issue-profile.v2", node: "问题综合分析",
            purpose: "基于已确认事件生成问题滚动综合档案",
            source: "ProjectIssueAnalysisService.swift")
        return try Self.parse(raw)
    }

    static func sourceMaterial(issue: ProjectIssue, records: [MeetingRecord]) -> String {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let events = issue.events.sorted { $0.occurredAt < $1.occurredAt }
            .map { event in
                let evidence = event.evidence.isEmpty
                    ? "无时间码" : event.evidence.joined(separator: "、")
                let context = recordsByID[event.meetingID].map {
                    transcriptContext(record: $0, evidence: event.evidence)
                } ?? "（会议记录当前不可用）"
                return """
                ### \(event.meetingTitle)｜\(dateText(event.occurredAt))
                - 状态：\(event.previousStatus ?? "未记录") → \(event.currentStatus.isEmpty ? "待确认" : event.currentStatus)
                - 标题：\(event.title)
                - 背景：\(emptyFallback(event.background))
                - 根因：\(emptyFallback(event.rootCause))
                - 方案：\(emptyFallback(event.solution))
                - 本次进展：\(emptyFallback(event.progress))
                - 证据：\(evidence)
                - 逐字稿证据上下文：
                \(context)
                """
            }.joined(separator: "\n\n")

        return """
        请分析以下已经由用户确认关联的单一项目问题。

        问题 ID：\(issue.id)
        当前标题：\(issue.title)
        别名：\(issue.aliases.isEmpty ? "无" : issue.aliases.joined(separator: "、"))
        当前状态：\(issue.status.isEmpty ? "待确认" : issue.status)
        当前背景：\(emptyFallback(issue.background))
        当前根因：\(emptyFallback(issue.rootCause))
        当前方案：\(emptyFallback(issue.solution))

        已确认关联的历史事件：
        \(events.isEmpty ? "（没有历史事件）" : events)
        """
    }

    private static let systemPrompt = """
    你是会议项目的问题分析助手。只能使用用户提供的、已经确认关联到同一问题的材料，不得引入常识猜测或虚构事实。
    summary 必须是一个完整自然段，对整个问题作有信息密度的综合总结：交代必要背景和影响，概括关键演变与已采取方案，说明当前最可信判断、仍存的不确定性、当前状态和关键下一步。不要列点、不要加标题、不要逐场复述，也不要堆砌细节；通常控制在 300–450 字，材料较少时可以更短。
    timeline 按日期从早到晚，每场关联会议最多一条；change 只用一句话概括该次变化，控制在 50 字以内。
    summary 和 timeline 均不得输出逐字稿时间戳、证据编号或方括号时间码。区分事实和推测，不要替用户修改状态。
    只输出合法 JSON：{"summary":"一段高度总结","timeline":[{"date":"YYYY-MM-DD","meetingTitle":"会议标题","change":"一句变化"}]}
    """

    static func parse(_ raw: String) throws -> Report {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = candidate.firstIndex(of: "{"), let last = candidate.lastIndex(of: "}") {
            candidate = String(candidate[first...last])
        }
        guard let data = candidate.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidResponse
        }
        return Report(
            summary: stripTimecodes(response.summary),
            timeline: response.timeline.map {
                .init(date: $0.date, meetingTitle: $0.meetingTitle,
                      change: stripTimecodes($0.change))
            })
    }

    private static func stripTimecodes(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"\s*[（(]?\[\d{1,2}:\d{2}(?::\d{2})?\][）)]?"#,
            with: "", options: .regularExpression)
    }

    enum Failure: LocalizedError {
        case invalidResponse
        var errorDescription: String? { "模型没有返回有效的问题总结。" }
    }

    private static func transcriptContext(record: MeetingRecord,
                                          evidence: [String]) -> String {
        let seconds = evidence.compactMap(parseEvidenceTime)
        guard !seconds.isEmpty else { return "（没有可定位的逐字稿时间码）" }
        let matching = record.transcript.segments.filter { segment in
            seconds.contains { abs(segment.start - $0) <= 45 }
        }
        guard !matching.isEmpty else { return "（时间码在当前逐字稿中未找到）" }
        return matching.prefix(80).map {
            let speaker = $0.speaker.map { "【\($0)】" } ?? ""
            return "[\($0.timecode)] \(speaker)\($0.text)"
        }.joined(separator: "\n")
    }

    private static func parseEvidenceTime(_ raw: String) -> TimeInterval? {
        let pattern = #"(?<!\d)(\d{1,2}:\d{2}(?::\d{2})?)(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) else { return nil }
        let value = String(raw[range])
        let parts = value.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        return nil
    }

    private static func emptyFallback(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未记录" : value
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
