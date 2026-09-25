import Foundation

struct ProjectIssueAnalysisService {
    struct Report: Sendable, Equatable {
        struct TimelineItem: Sendable, Equatable {
            let date: String
            let meetingTitle: String
            let change: String
            let stage: String?
            let status: String?
            let situation: String?
            let evidence: String?
            let nextStep: String?
        }
        let summary: String
        let overview: String
        let stableConclusion: String
        let latestProgress: String
        let unresolvedItems: [String]
        let nextSteps: [String]
        let diagnosticGuardrails: [String]
        let conclusionChanged: Bool
        let conclusionChangeReason: String?
        let timeline: [TimelineItem]
        let recoveredMeetingTitleCount: Int
        let wasUpToDate: Bool

        init(summary: String, timeline: [TimelineItem], overview: String? = nil,
             stableConclusion: String? = nil, latestProgress: String? = nil,
             unresolvedItems: [String] = [], nextSteps: [String] = [],
             diagnosticGuardrails: [String] = [], conclusionChanged: Bool = false,
             conclusionChangeReason: String? = nil,
             recoveredMeetingTitleCount: Int = 0,
             wasUpToDate: Bool = false) {
            self.summary = summary
            self.overview = overview ?? stableConclusion ?? summary
            self.stableConclusion = stableConclusion ?? summary
            self.latestProgress = latestProgress ?? ""
            self.unresolvedItems = unresolvedItems
            self.nextSteps = nextSteps
            self.diagnosticGuardrails = diagnosticGuardrails
            self.conclusionChanged = conclusionChanged
            self.conclusionChangeReason = conclusionChangeReason
            self.timeline = timeline
            self.recoveredMeetingTitleCount = recoveredMeetingTitleCount
            self.wasUpToDate = wasUpToDate
        }
    }

    private struct Response: Codable {
        struct TimelineItem: Codable {
            let date: String?
            let meetingTitle: String?
            let change: String?
            let stage: String?
            let status: String?
            let situation: String?
            let evidence: String?
            let nextStep: String?
        }
        let summary: String?
        let overview: String?
        let stableConclusion: String?
        let latestProgress: String?
        let unresolvedItems: [String]?
        let nextSteps: [String]?
        let diagnosticGuardrails: [String]?
        let conclusionChanged: Bool?
        let conclusionChangeReason: String?
        let timeline: [TimelineItem]?
    }

    private struct AnalysisInput {
        enum Mode: String { case full = "完整重建", incremental = "增量更新" }
        let mode: Mode
        let material: String
        let eventsForTimeline: [ProjectIssueEvent]
        let previous: ProjectIssueAnalysis?
    }

    let settings: Settings

    static func estimatedTokens(issue: ProjectIssue, records: [MeetingRecord],
                                previousAnalysis: ProjectIssueAnalysis? = nil) -> Int {
        let input = analysisInput(
            issue: issue, records: records, previousAnalysis: previousAnalysis)
        if input.mode == .incremental && input.eventsForTimeline.isEmpty {
            return 0
        }
        return TokenEstimator.count(systemPrompt + "\n" + input.material) + 1_200
    }

    func analyze(issue: ProjectIssue, records: [MeetingRecord],
                 previousAnalysis: ProjectIssueAnalysis? = nil) async throws -> Report {
        let input = Self.analysisInput(
            issue: issue, records: records, previousAnalysis: previousAnalysis)
        let material = input.material
        let previousDebug = PipelineDebugRegistry.active
        let ownedDebug = previousDebug == nil && settings.pipelineDebugEnabled
            ? try? PipelineDebugSession(
                pausesAtNodeStart: settings.pipelineDebugPauseAtNodeStart)
            : nil
        let debug = ownedDebug ?? previousDebug
        if let ownedDebug { PipelineDebugRegistry.install(ownedDebug) }
        defer {
            if ownedDebug != nil { PipelineDebugRegistry.install(previousDebug) }
        }

        do {
            let skipsModel = input.mode == .incremental
                && input.eventsForTimeline.isEmpty && input.previous != nil
            let estimatedTokenCount = skipsModel
                ? 0 : TokenEstimator.count(Self.systemPrompt + "\n" + material) + 1_200
            try await debug?.beginNode("问题专题分析", input: """
            操作：重新分析
            问题 ID：\(issue.id)
            问题标题：\(issue.title)
            分析模式：\(input.mode.rawValue)
            分析器版本：v\(ProjectIssueAnalysis.currentAnalyzerVersion)
            上次分析器版本：\(input.previous?.analyzerVersion.map { "v\($0)" } ?? "旧版或未记录")
            已确认历史事件：\(issue.events.count) 条
            本次提交事件：\(input.eventsForTimeline.count) 条
            预计 Token：\(estimatedTokenCount)
            模型调用：\(skipsModel ? "跳过（档案已覆盖全部历史事件）" : "执行")

            完整输入：
            \(material)
            """)
            if skipsModel, let previous = input.previous {
                let report = Self.report(from: previous, wasUpToDate: true)
                debug?.progress(
                    "问题专题分析",
                    "当前档案已覆盖全部 \(issue.events.count) 条历史事件，跳过模型调用。")
                debug?.endNode("问题专题分析", output: """
                档案状态：已是最新
                模型调用：跳过
                Token：0
                时间线：\(report.timeline.count) 条
                """)
                ownedDebug?.runSummary(
                    status: "成功", cache: "档案已是最新", screen: "不适用",
                    extra: "问题：\(issue.title)\n模式：\(input.mode.rawValue)\n模型调用：跳过\n时间线：\(report.timeline.count) 条",
                    node: "问题专题分析", tokenOverride: 0)
                return report
            }
            debug?.progress("问题专题分析", "已组装历史问题材料，正在调用模型…")
            let raw = try await ModelTextClient(settings: settings).complete(
                system: Self.systemPrompt, user: material,
                promptID: "issue-profile.v7", node: "问题专题分析",
                purpose: "维护问题全貌、稳定结论、最新进展和问题时间线",
                source: "ProjectIssueAnalysisService.swift")
            debug?.progress("问题专题分析", "模型返回完成，正在校验时间线结构…")
            let parsed = try Self.parse(raw, fallbackEvents: input.eventsForTimeline)
            let report = Self.finalize(parsed, input: input)
            if report.recoveredMeetingTitleCount > 0 {
                debug?.progress(
                    "问题专题分析",
                    "模型遗漏了 \(report.recoveredMeetingTitleCount) 个会议标题，已根据问题历史事件自动补全。")
            }
            debug?.endNode("问题专题分析", output: Self.debugOutput(report))
            ownedDebug?.runSummary(
                status: "成功", cache: "不适用", screen: "不适用",
                extra: "问题：\(issue.title)\n模式：\(input.mode.rawValue)\n时间线：\(report.timeline.count) 条",
                node: "问题专题分析")
            return report
        } catch {
            debug?.nodeWarning("问题专题分析", detail: "失败：\(error.localizedDescription)")
            debug?.endNode("问题专题分析", output: "失败：\(error.localizedDescription)")
            ownedDebug?.runSummary(
                status: "失败", cache: "不适用", screen: "不适用",
                extra: "问题：\(issue.title)\n错误：\(error.localizedDescription)",
                node: "问题专题分析")
            throw error
        }
    }

    static func sourceMaterial(issue: ProjectIssue, records: [MeetingRecord]) -> String {
        fullSourceMaterial(issue: issue, records: records)
    }

    private static func analysisInput(
        issue: ProjectIssue, records: [MeetingRecord],
        previousAnalysis: ProjectIssueAnalysis?
    ) -> AnalysisInput {
        let previousStable = cleaned(previousAnalysis?.stableConclusion)
        guard let previousAnalysis, let previousStable,
              previousAnalysis.analyzerVersion == ProjectIssueAnalysis.currentAnalyzerVersion else {
            return AnalysisInput(
                mode: .full,
                material: fullSourceMaterial(issue: issue, records: records),
                eventsForTimeline: issue.events.sorted { $0.occurredAt < $1.occurredAt },
                previous: nil)
        }

        let previousIDs = Set(previousAnalysis.sourceEventIDs)
        let newEvents = issue.events.filter { !previousIDs.contains($0.id) }
            .sorted { $0.occurredAt < $1.occurredAt }
        let oldTimeline = (previousAnalysis.timeline ?? []).map { item in
            """
            - \(item.date)｜\(item.meetingTitle)｜阶段：\(item.stage ?? "未明确")｜状态：\(item.status ?? "未明确")
              当时情况：\(item.situation ?? "未记录")
              本次变化：\(item.change)
              关键依据：\(item.evidence ?? "未记录")
              下一步：\(item.nextStep ?? "未记录")
            """
        }.joined(separator: "\n")
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let newMaterial = eventMaterial(newEvents, recordsByID: recordsByID)
        let material = """
        请以增量方式更新以下已确认项目问题档案。上次档案是本次更新的稳定基线；只使用新增事件更新相应部分。

        问题 ID：\(issue.id)
        当前标题：\(issue.title)
        当前状态：\(issue.status.isEmpty ? "待确认" : issue.status)

        上次稳定档案：
        - 问题全貌：\(cleaned(previousAnalysis.overview) ?? cleaned(previousAnalysis.summary) ?? "未记录")
        - 稳定结论：\(previousStable)
        - 最新进展：\(cleaned(previousAnalysis.latestProgress) ?? "未记录")
        - 未解决事项：\(listText(previousAnalysis.unresolvedItems))
        - 下一步：\(listText(previousAnalysis.nextSteps))
        - 诊断边界：\(listText(previousAnalysis.diagnosticGuardrails))

        上次已确认时间线：
        \(oldTimeline.isEmpty ? "（无）" : oldTimeline)

        本次新增事件：
        \(newMaterial.isEmpty ? "（没有新增事件；只校正档案结构和表达，不得改变事实结论）" : newMaterial)

        注意：台账中的“最新字段”只反映最近一场会议的记录视角，不是自动覆盖历史证据的权威结论：
        - 最新背景快照：\(emptyFallback(issue.background))
        - 最新根因快照：\(emptyFallback(issue.rootCause))
        - 最新方案快照：\(emptyFallback(issue.solution))
        """
        return AnalysisInput(
            mode: .incremental, material: material,
            eventsForTimeline: newEvents, previous: previousAnalysis)
    }

    private static func fullSourceMaterial(issue: ProjectIssue,
                                           records: [MeetingRecord]) -> String {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let sortedEvents = issue.events.sorted { $0.occurredAt < $1.occurredAt }
        let events = eventMaterial(sortedEvents, recordsByID: recordsByID)

        return """
        请分析以下已经由用户确认关联的单一项目问题。

        问题 ID：\(issue.id)
        当前标题：\(issue.title)
        别名：\(issue.aliases.isEmpty ? "无" : issue.aliases.joined(separator: "、"))
        当前状态：\(issue.status.isEmpty ? "待确认" : issue.status)
        注意：以下三个台账字段来自最近一次会议，只是最新快照，不得覆盖多场历史事件形成的证据结论。
        最新背景快照：\(emptyFallback(issue.background))
        最新根因快照：\(emptyFallback(issue.rootCause))
        最新方案快照：\(emptyFallback(issue.solution))

        已确认关联的历史事件：
        \(events.isEmpty ? "（没有历史事件）" : events)
        """
    }

    private static func eventMaterial(
        _ events: [ProjectIssueEvent], recordsByID: [UUID: MeetingRecord]
    ) -> String {
        events.map { event in
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
    }

    private static func listText(_ values: [String]?) -> String {
        let values = (values ?? []).compactMap(cleaned)
        return values.isEmpty ? "未记录" : values.joined(separator: "；")
    }

    private static let systemPrompt = """
    你是会议项目的问题档案维护助手。只能使用用户提供且已确认关联到同一问题的材料，不得引入常识猜测或虚构事实。

    你的首要任务是同时维护面向用户的完整叙事和供后续增量分析使用的结构化结论，避免最新会议覆盖此前已经有证据支持的判断：
    - overview：面向用户的“问题全貌”，必须让第一次阅读的人无需展开时间线也能理解问题。用 4–6 个连贯短句，按“最初现象与业务影响 → 关键排查过程及判断转折 → 已实施方案和验证结果 → 最终共识、当前状态与剩余边界”组织。必须保留影响结论成立的反证、对照测试、排查受阻或责任判断变化，解释为什么得到最终结论，而不是只写最终根因。不要逐场复述会议，不要使用标题或项目符号。控制在 280–450 字；材料较少时可自然缩短，但不得为了凑字虚构内容。
    - stableConclusion：跨会议仍然成立的稳定结论，固定写成 3 个简短句子，依次说明“最可信结论”“关键触发链路”“当前处置与未闭环边界”。最近材料只是没有补充新日志，不能据此否定旧结论，但输出中不得出现“不能因后续会议未补充而否定”“材料未推翻旧结论”等分析守则或自我辩护措辞。除非辨别根因所必需，不要堆叠函数名和实现细节。控制在 160–230 字，只保留决定性信息。
    - latestProgress：只概括最新阶段新增了什么，固定写成 2–3 个简短句子，依次说明“已完成或已验证内容”“仍在进行的事项或下一检查点”。必须与稳定结论兼容，控制在 100–160 字。若材料已经说明故障现象、修复目标或明确的验证内容，下一检查点必须保留或概括最多 3 项可验证的验收标准，不得退化成笼统的“部署并验证”。不得写模型操作、增量分析、新增事件数量、档案结构调整或文字校正等内部处理说明。
    - unresolvedItems：尚未闭环或证据仍不足的事项。区分“根因已定位”与“厂商根治未完成”，也区分“测试验证通过”与“生产部署完成”。合并同类项，最多 4 条。
    - nextSteps：材料中明确提出、仍需执行的后续动作；不要自行创造任务。若材料能够明确修复目标和原故障表现，应把对应的验收项保留下来，而不是只写“验证”。按执行顺序合并，最多 5 条。
    - diagnosticGuardrails：未来排障时不能直接沿用旧归因的边界条件。例如新现象缺少相同日志时应重新取证。这是诊断边界，不是对既有结论的否定。只保留最关键的边界，最多 4 条。
    - conclusionChanged：只有新增材料出现明确的反证、修正证据或新的最终结论，确实需要改写 stableConclusion 时才为 true。
    - conclusionChangeReason：conclusionChanged 为 true 时必须说明“哪条新增证据推翻或修正了哪项旧结论”；否则输出空字符串。

    若输入包含“上次稳定档案”，它就是本次更新的基线。没有明确反证时，stableConclusion 应保持原意，不能因为措辞变化、缺少新日志、部署方式变化或临时方案变化而改写根因。overview 必须在保留既有起因、关键排查转折和最终共识的基础上吸收新增事件，不能只改写成最新状态摘要。

    timeline 按日期从早到晚。在完整重建模式中覆盖所有提交会议；在增量更新模式中只输出本次新增事件，每场最多一条。每条必须让读者脱离总结合集也能理解该阶段：
    - date：该次会议日期，必须输出，格式为 YYYY-MM-DD。
    - meetingTitle：该次会议的原始标题，必须逐字输出，不得省略、改写或用问题标题代替。
    - stage：该阶段类型，只能简短填写“发现”“定位”“方案”“验证”“受阻”“闭环”或最接近的词。
    - status：该次会议结束时的问题状态，例如“进行中”“等待客户”“已闭环”；材料未明确时写“未明确”。
    - situation：进入该次会议时的问题或阻塞背景，1 句话，控制在 70 字以内。
    - change：本次会议新增的关键进展或判断，1 句话，控制在 80 字以内，不能只写“有进展”“继续跟进”等空泛表述。
    - evidence：支持本次变化的最关键事实、数据或现象，1 句话；没有明确依据时写空字符串。
    - nextStep：该次会议后明确的下一步，1 句话；若会议明确了修复目标或可验证的故障表现，应保留具体验收项，不得只写“部署并验证”；已闭环或材料没有下一步时写空字符串。
    所有字段均不得输出逐字稿时间戳、证据编号或方括号时间码。区分事实和推测，不要替用户修改状态。数组没有内容时输出空数组。
    证据口径必须严格分层：明确区分“故障前正常基线”“故障期间观测”“UAT/测试环境验证”“生产环境验证”和“目标值”。不得把历史正常速率、预期目标或小规模 UAT 结果改写为生产修复后的实测结果；“客户认可”“达到要求”或“问题闭环”也不自动等于已完成生产部署。结构化事件字段与逐字稿证据上下文不一致时，以逐字稿中明确说出的事实为准，并在 overview、latestProgress、timeline 中保留环境和数据规模限定。
    同一项测试或结论在后续会议中被重复回顾时，不得写成多轮独立验证。若近似数据口径不同（例如先称“100多万”，后称“约180万”），除非材料明确说明是两次测试，否则合并为一项证据并简要标注后续会议采用的更具体口径，不能累加验证次数。
    只输出合法 JSON：{"overview":"问题全貌","stableConclusion":"稳定结论","latestProgress":"最新进展","unresolvedItems":["未解决事项"],"nextSteps":["下一步"],"diagnosticGuardrails":["诊断边界"],"conclusionChanged":false,"conclusionChangeReason":"","timeline":[{"date":"YYYY-MM-DD","meetingTitle":"会议标题","stage":"阶段","status":"本次结束状态","situation":"当时情况","change":"本次变化","evidence":"关键依据或空字符串","nextStep":"下一步或空字符串"}]}
    """

    static func parse(_ raw: String,
                      fallbackEvents: [ProjectIssueEvent] = []) throws -> Report {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = candidate.firstIndex(of: "{"), let last = candidate.lastIndex(of: "}") {
            candidate = String(candidate[first...last])
        }
        guard let data = candidate.data(using: .utf8) else {
            throw Failure.invalidResponse("模型输出不是有效的 UTF-8 文本")
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw Failure.invalidResponse(decodingDetail(error))
        }
        let stableConclusion = cleaned(response.stableConclusion)
            .map(userFacingStableConclusion) ?? cleaned(response.summary)
        guard let stableConclusion else {
            throw Failure.invalidResponse("缺少非空的 stableConclusion 或 summary")
        }
        guard let rawTimeline = response.timeline else {
            throw Failure.invalidResponse("缺少 timeline 数组")
        }

        var remainingEvents = fallbackEvents.sorted { $0.occurredAt < $1.occurredAt }
        var recoveredTitles = 0
        var timeline: [Report.TimelineItem] = []
        timeline.reserveCapacity(rawTimeline.count)
        for (index, item) in rawTimeline.enumerated() {
            let rawDate = cleaned(item.date)
            let eventIndex = rawDate.flatMap { date in
                remainingEvents.firstIndex { dateText($0.occurredAt) == date }
            } ?? (remainingEvents.isEmpty ? nil : remainingEvents.startIndex)
            let event = eventIndex.map { remainingEvents.remove(at: $0) }
            guard let date = rawDate ?? event.map({ dateText($0.occurredAt) }) else {
                throw Failure.invalidResponse("timeline 第 \(index + 1) 条缺少 date，且无法从历史事件补全")
            }
            let suppliedTitle = cleaned(item.meetingTitle)
            let meetingTitle = suppliedTitle ?? cleaned(event?.meetingTitle) ?? "关联会议"
            if suppliedTitle == nil { recoveredTitles += 1 }
            guard let change = cleaned(item.change) ?? cleaned(event?.progress) else {
                throw Failure.invalidResponse("timeline 第 \(index + 1) 条缺少 change，且无法从历史事件补全")
            }
            timeline.append(.init(
                date: date, meetingTitle: meetingTitle, change: change,
                stage: cleaned(item.stage), status: cleaned(item.status),
                situation: cleaned(item.situation), evidence: cleaned(item.evidence),
                nextStep: cleaned(item.nextStep)))
        }
        let latestProgress = userFacingLatestProgress(response.latestProgress ?? "")
        let overview = cleaned(response.overview) ?? stableConclusion
        let unresolvedItems = cleanedList(response.unresolvedItems)
        let nextSteps = cleanedList(response.nextSteps)
        let diagnosticGuardrails = cleanedList(response.diagnosticGuardrails)
        let isStructured = cleaned(response.stableConclusion) != nil
        let summary = isStructured
            ? composeSummary(
                stableConclusion: stableConclusion,
                latestProgress: latestProgress,
                unresolvedItems: unresolvedItems,
                nextSteps: nextSteps,
                diagnosticGuardrails: diagnosticGuardrails)
            : stableConclusion
        return Report(
            summary: summary, timeline: timeline, overview: overview,
            stableConclusion: stableConclusion, latestProgress: latestProgress,
            unresolvedItems: unresolvedItems, nextSteps: nextSteps,
            diagnosticGuardrails: diagnosticGuardrails,
            conclusionChanged: response.conclusionChanged ?? false,
            conclusionChangeReason: cleaned(response.conclusionChangeReason),
            recoveredMeetingTitleCount: recoveredTitles)
    }

    private static func finalize(_ report: Report, input: AnalysisInput) -> Report {
        guard input.mode == .incremental, let previous = input.previous else {
            return reportWithSortedTimeline(report)
        }
        return mergeIncrementalReport(report, previous: previous)
    }

    static func mergeIncrementalReport(
        _ report: Report, previous: ProjectIssueAnalysis
    ) -> Report {
        let previousStable = cleaned(previous.stableConclusion)
            .map(userFacingStableConclusion)
            ?? cleaned(previous.summary).map(userFacingStableConclusion)
            ?? report.stableConclusion
        let acceptsConclusionChange = report.conclusionChanged
            && cleaned(report.conclusionChangeReason) != nil
        let stableConclusion = acceptsConclusionChange
            ? report.stableConclusion : previousStable
        let latestProgress = cleaned(userFacingLatestProgress(report.latestProgress))
            ?? cleaned(userFacingLatestProgress(previous.latestProgress ?? "")) ?? ""
        let overview = cleaned(report.overview)
            ?? cleaned(previous.overview)
            ?? cleaned(previous.summary)
            ?? stableConclusion
        let unresolvedItems = report.unresolvedItems.isEmpty
            ? (previous.unresolvedItems ?? []) : report.unresolvedItems
        let nextSteps = report.nextSteps.isEmpty
            ? (previous.nextSteps ?? []) : report.nextSteps
        let diagnosticGuardrails = report.diagnosticGuardrails.isEmpty
            ? (previous.diagnosticGuardrails ?? []) : report.diagnosticGuardrails

        var timeline = (previous.timeline ?? []).map {
            Report.TimelineItem(
                date: $0.date, meetingTitle: $0.meetingTitle, change: $0.change,
                stage: $0.stage, status: $0.status, situation: $0.situation,
                evidence: $0.evidence, nextStep: $0.nextStep)
        }
        for item in report.timeline {
            if let index = timeline.firstIndex(where: {
                $0.date == item.date && $0.meetingTitle == item.meetingTitle
            }) {
                timeline[index] = item
            } else {
                timeline.append(item)
            }
        }
        timeline.sort {
            $0.date == $1.date
                ? $0.meetingTitle.localizedStandardCompare($1.meetingTitle) == .orderedAscending
                : $0.date < $1.date
        }
        return Report(
            summary: composeSummary(
                stableConclusion: stableConclusion,
                latestProgress: latestProgress,
                unresolvedItems: unresolvedItems,
                nextSteps: nextSteps,
                diagnosticGuardrails: diagnosticGuardrails),
            timeline: timeline, overview: overview, stableConclusion: stableConclusion,
            latestProgress: latestProgress, unresolvedItems: unresolvedItems,
            nextSteps: nextSteps, diagnosticGuardrails: diagnosticGuardrails,
            conclusionChanged: acceptsConclusionChange,
            conclusionChangeReason: acceptsConclusionChange
                ? cleaned(report.conclusionChangeReason) : nil,
            recoveredMeetingTitleCount: report.recoveredMeetingTitleCount)
    }

    private static func reportWithSortedTimeline(_ report: Report) -> Report {
        Report(
            summary: report.summary,
            timeline: report.timeline.sorted {
                $0.date == $1.date
                    ? $0.meetingTitle.localizedStandardCompare($1.meetingTitle) == .orderedAscending
                    : $0.date < $1.date
            },
            overview: report.overview,
            stableConclusion: report.stableConclusion,
            latestProgress: report.latestProgress,
            unresolvedItems: report.unresolvedItems,
            nextSteps: report.nextSteps,
            diagnosticGuardrails: report.diagnosticGuardrails,
            conclusionChanged: report.conclusionChanged,
            conclusionChangeReason: report.conclusionChangeReason,
            recoveredMeetingTitleCount: report.recoveredMeetingTitleCount,
            wasUpToDate: report.wasUpToDate)
    }

    private static func report(from previous: ProjectIssueAnalysis,
                               wasUpToDate: Bool) -> Report {
        let stableConclusion = cleaned(previous.stableConclusion)
            .map(userFacingStableConclusion)
            ?? cleaned(previous.summary).map(userFacingStableConclusion)
            ?? "暂无稳定结论"
        let latestProgress = userFacingLatestProgress(previous.latestProgress ?? "")
        let overview = cleaned(previous.overview)
            ?? cleaned(previous.summary)
            ?? stableConclusion
        let unresolvedItems = previous.unresolvedItems ?? []
        let nextSteps = previous.nextSteps ?? []
        let diagnosticGuardrails = previous.diagnosticGuardrails ?? []
        var timeline: [Report.TimelineItem] = (previous.timeline ?? []).map { item in
            Report.TimelineItem(
                date: item.date, meetingTitle: item.meetingTitle, change: item.change,
                stage: item.stage, status: item.status, situation: item.situation,
                evidence: item.evidence, nextStep: item.nextStep)
        }
        timeline.sort {
            $0.date == $1.date
                ? $0.meetingTitle.localizedStandardCompare($1.meetingTitle) == .orderedAscending
                : $0.date < $1.date
        }
        return Report(
            summary: composeSummary(
                stableConclusion: stableConclusion,
                latestProgress: latestProgress,
                unresolvedItems: unresolvedItems,
                nextSteps: nextSteps,
                diagnosticGuardrails: diagnosticGuardrails),
            timeline: timeline,
            overview: overview,
            stableConclusion: stableConclusion,
            latestProgress: latestProgress,
            unresolvedItems: unresolvedItems,
            nextSteps: nextSteps,
            diagnosticGuardrails: diagnosticGuardrails,
            conclusionChangeReason: cleaned(previous.conclusionChangeReason),
            wasUpToDate: wasUpToDate)
    }

    static func userFacingLatestProgress(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"[^。！？\n]*(?:本次无新增事件|仅校正档案结构和表达)[^。！？\n]*[。！？]?"#,
            with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func userFacingStableConclusion(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"，?(?:不能|不得)因后续会议[^。！？]*(?:否定|推翻)[^。！？]*"#,
            with: "", options: .regularExpression)
            .replacingOccurrences(
                of: #"，?材料未[^。！？]*(?:否定|推翻)[^。！？]*"#,
                with: "", options: .regularExpression)
            .replacingOccurrences(of: "。。", with: "。")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func composeSummary(
        stableConclusion: String, latestProgress: String,
        unresolvedItems: [String], nextSteps: [String],
        diagnosticGuardrails: [String]
    ) -> String {
        var sections = ["稳定结论：\(stableConclusion)"]
        if let progress = cleaned(latestProgress) {
            sections.append("最新进展：\(progress)")
        }
        if !unresolvedItems.isEmpty {
            sections.append("尚未解决：\n- \(unresolvedItems.joined(separator: "\n- "))")
        }
        if !nextSteps.isEmpty {
            sections.append("下一步：\n- \(nextSteps.joined(separator: "\n- "))")
        }
        if !diagnosticGuardrails.isEmpty {
            sections.append("诊断边界：\n- \(diagnosticGuardrails.joined(separator: "\n- "))")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func cleanedList(_ values: [String]?) -> [String] {
        (values ?? []).compactMap(cleaned)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = stripTimecodes(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func decodingDetail(_ error: Error) -> String {
        guard let error = error as? DecodingError else {
            return "JSON 解析失败：\(error.localizedDescription)"
        }
        switch error {
        case .dataCorrupted(let context):
            return "JSON 内容损坏：\(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "缺少字段 \(key.stringValue)（\(codingPath(context.codingPath))）"
        case .typeMismatch(_, let context):
            return "字段类型错误（\(codingPath(context.codingPath))：\(context.debugDescription)）"
        case .valueNotFound(_, let context):
            return "字段值为空（\(codingPath(context.codingPath))：\(context.debugDescription)）"
        @unknown default:
            return "JSON 解析失败：\(error.localizedDescription)"
        }
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        let value = path.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "根节点" : value
    }

    private static func debugOutput(_ report: Report) -> String {
        let items = report.timeline.enumerated().map { index, item in
            """
            \(index + 1). \(item.date)｜\(item.meetingTitle)
            阶段：\(item.stage ?? "未明确")
            状态：\(item.status ?? "未明确")
            当时情况：\(item.situation ?? "未提供")
            本次变化：\(item.change)
            关键依据：\(item.evidence ?? "未提供")
            下一步：\(item.nextStep ?? "未提供")
            """
        }.joined(separator: "\n\n")
        return """
        问题全貌：
        \(report.overview)

        稳定结论：
        \(report.stableConclusion)

        最新进展：
        \(report.latestProgress.isEmpty ? "<空>" : report.latestProgress)

        尚未解决：
        \(report.unresolvedItems.isEmpty ? "<空>" : report.unresolvedItems.map { "- \($0)" }.joined(separator: "\n"))

        下一步：
        \(report.nextSteps.isEmpty ? "<空>" : report.nextSteps.map { "- \($0)" }.joined(separator: "\n"))

        诊断边界：
        \(report.diagnosticGuardrails.isEmpty ? "<空>" : report.diagnosticGuardrails.map { "- \($0)" }.joined(separator: "\n"))

        稳定结论变化：\(report.conclusionChanged ? "是" : "否")
        变化理由：\(report.conclusionChangeReason ?? "<空>")

        综合总结：
        \(report.summary)

        时间线（\(report.timeline.count) 条）：
        \(items.isEmpty ? "<空>" : items)
        """
    }

    private static func stripTimecodes(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"\s*[（(]?\[\d{1,2}:\d{2}(?::\d{2})?\][）)]?"#,
            with: "", options: .regularExpression)
    }

    enum Failure: LocalizedError {
        case invalidResponse(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse(let detail):
                return "模型返回格式无法解析：\(detail)。"
            }
        }
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
