import Foundation

/// Asks the text model where screen evidence is most likely to resolve an
/// ambiguity or recover a dense fact that periodic sampling may have missed.
struct AdaptiveFramePlanner {
    struct Request: Codable, Equatable, Sendable {
        let seconds: TimeInterval
        let reason: String
        /// How far around this utterance the relevant screen is likely to be.
        let radius: TimeInterval
    }

    let settings: Settings

    private static let ambiguityTerms = [
        "这里", "这边", "这个", "那个", "如下", "上面", "下面", "屏幕", "画面",
        "图里", "表里", "可以看到", "大家看", "看一下", "展示", "演示"
    ]
    private static let evidenceTerms = [
        "报错", "错误", "告警", "日志", "截图", "架构", "拓扑", "图表", "趋势",
        "版本", "日期", "截止", "数据", "指标", "结果", "列表", "清单"
    ]

    /// Cheap local gate. It also reduces a long meeting to relevant snippets
    /// distributed across the whole timeline instead of truncating its tail.
    static func candidateTimeline(from transcript: Transcript, limit: Int = 30) -> String {
        let scored = transcript.segments.compactMap { segment -> (TranscriptSegment, Int)? in
            let text = segment.text
            var score = 0
            if ambiguityTerms.contains(where: text.contains) { score += 4 }
            if evidenceTerms.contains(where: text.contains) { score += 2 }
            let digits = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
            if digits >= 3 { score += 2 }
            if text.count >= 80 { score += 1 }
            if text.contains("〔音〕") || text.contains("听不清") || text.contains("不确定") { score += 3 }
            return score > 0 ? (segment, score) : nil
        }
        let chosen = scored.sorted {
            $0.1 == $1.1 ? $0.0.start < $1.0.start : $0.1 > $1.1
        }.prefix(limit).map(\.0).sorted { $0.start < $1.start }
        return chosen.map { "[\($0.timecode)] \($0.text)" }.joined(separator: "\n")
    }

    func plan(transcript: Transcript, duration: TimeInterval) async throws -> [Request] {
        let candidates = Self.candidateTimeline(from: transcript)
        guard !candidates.isEmpty else { return [] }
        let systemPrompt = "你负责为会议录像选择需要补看屏幕的时间点。只输出 JSON，不要解释。"
        let userPrompt = """
        阅读逐字稿，找出屏幕画面可能补充关键事实的节点，例如：信息密集的汇报、含糊的“这里/这个”、
        数字日期版本号、图表架构、演示结果、报错信息或语音识别明显可疑的专有名词。
        只选择真正值得补看画面的节点，最多 6 个；没有则返回空数组。
        根据画面可能出现的时机设置 radius：普通指代 2-3 秒，图表讲解 4-6 秒，演示结果 6-8 秒。
        输出格式：{"requests":[{"seconds":123.4,"reason":"需要核对图表数字","radius":5}]}
        seconds 必须在 0 到 \(duration) 之间。

        以下只是在本机预筛出的候选片段，覆盖整场会议：
        \(candidates)
        """
        let debug = PipelineDebugRegistry.active
        try await debug?.beginNode("关键画面规划", input: """
        系统提示词：\n\(systemPrompt)

        用户输入：\n\(userPrompt)
        """)
        let context = (TokenUsageContext.current ?? TokenUsageContext(feature: "画面节点规划"))
            .replacingFeature("画面节点规划")
        let heartbeat = Task {
            var waited = 0
            while !Task.isCancelled {
                let interval = waited < 30 ? 10 : 30
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                waited += interval
                if !Task.isCancelled {
                    debug?.progress("关键画面规划", "模型仍在运行，已等待 \(waited / 60):\(String(format: "%02d", waited % 60))")
                }
            }
        }
        defer { heartbeat.cancel() }
        let raw = try await TokenUsageContext.$current.withValue(context) {
            try await ModelTextClient(settings: settings).complete(
            system: systemPrompt,
            user: userPrompt,
            timeout: 180, promptID: "frame-planning.v1", node: "关键画面规划",
            purpose: "从本地候选片段规划需要补看的画面时间点",
            source: "AdaptiveFramePlanner.swift")
        }
        let planned = Self.parse(raw, duration: duration)
        // A model may conservatively return an empty list (or malformed JSON)
        // even when the transcript explicitly says "看这里" during a screen
        // demonstration. Keep a small deterministic safety net so the adaptive
        // path cannot silently become a no-op on exactly those meetings.
        let result = planned.isEmpty
            ? Self.fallbackRequests(from: transcript, duration: duration)
            : planned
        let output = (try? String(data: JSONEncoder().encode(result), encoding: .utf8)) ?? raw
        debug?.endNode("关键画面规划", output: output)
        return result
    }

    static func fallbackRequests(from transcript: Transcript,
                                 duration: TimeInterval) -> [Request] {
        let candidates = transcript.segments.compactMap { segment -> (TranscriptSegment, Int)? in
            let text = segment.text
            let hasPointer = ambiguityTerms.contains(where: text.contains)
            let hasEvidence = evidenceTerms.contains(where: text.contains)
            let digitCount = text.unicodeScalars.filter {
                CharacterSet.decimalDigits.contains($0)
            }.count
            guard hasPointer || (hasEvidence && digitCount >= 2) else { return nil }
            return (segment, (hasPointer ? 4 : 0) + (hasEvidence ? 2 : 0) + min(digitCount, 3))
        }.sorted { $0.1 > $1.1 }

        var selected: [Request] = []
        for (segment, _) in candidates {
            guard !selected.contains(where: { abs($0.seconds - segment.start) < 15 }) else { continue }
            selected.append(Request(
                seconds: min(max(segment.start, 0), duration),
                reason: "逐字稿明确指向屏幕或包含需核对的数字信息",
                radius: 5))
            if selected.count == 3 { break }
        }
        return selected.sorted { $0.seconds < $1.seconds }
    }

    static func parse(_ raw: String, duration: TimeInterval) -> [Request] {
        struct Payload: Codable { let requests: [Request] }
        guard let first = raw.firstIndex(of: "{"), let last = raw.lastIndex(of: "}"),
              let data = String(raw[first...last]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [] }
        var seen = Set<Int>()
        return payload.requests.filter {
            $0.seconds >= 0 && $0.seconds <= duration && !$0.reason.isEmpty
                && $0.radius >= 1 && $0.radius <= 10
                && seen.insert(Int($0.seconds.rounded())).inserted
        }.prefix(6).map { $0 }
    }
}
