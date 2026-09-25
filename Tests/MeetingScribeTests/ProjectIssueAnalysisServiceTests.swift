import XCTest
@testable import MeetingScribe

final class ProjectIssueAnalysisServiceTests: XCTestCase {
    func testLegacyLedgerDecodesWithoutSavedIssueAnalyses() throws {
        let data = Data(#"{"actions":[],"proposals":[],"issues":[],"issueProposals":[]}"#.utf8)
        let ledger = try JSONDecoder().decode(ProjectLedger.self, from: data)
        XCTAssertTrue(ledger.issueAnalyses.isEmpty)
    }

    func testSavingIssueAnalysisPersistsAndReplacesPreviousReport() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-analysis-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let issue = ProjectIssue(
            id: "ISSUE-1", workspaceID: UUID(), title: "问题", aliases: [],
            background: "", rootCause: "", solution: "", status: "进行中",
            createdAt: Date(), updatedAt: Date(), sourceMeetingID: UUID(), events: [])
        try ProjectLedgerStore.save(ProjectLedger(issues: [issue]), to: url)

        let first = ProjectIssueAnalysisService.Report(summary: "第一版", timeline: [])
        let second = ProjectIssueAnalysisService.Report(
            summary: "第二版", timeline: [], overview: "第二版问题全貌")
        _ = try ProjectLedgerStore.saveIssueAnalysis(issue: issue, report: first, at: url)
        _ = try ProjectLedgerStore.saveIssueAnalysis(issue: issue, report: second, at: url)
        let loaded = try ProjectLedgerStore.load(from: url)

        XCTAssertEqual(loaded.issueAnalyses.count, 1)
        XCTAssertEqual(loaded.analysis(for: issue.id)?.summary, "第二版")
        XCTAssertEqual(loaded.analysis(for: issue.id)?.overview, "第二版问题全貌")
    }

    func testSavedAnalysisBecomesStaleWhenIssueGetsANewEvent() {
        let first = ProjectIssueEvent(
            kind: .created, occurredAt: Date(), meetingID: UUID(), meetingTitle: "首次会议",
            previousStatus: nil, currentStatus: "进行中", title: "问题", background: "",
            rootCause: "", solution: "", progress: "", evidence: [])
        var issue = ProjectIssue(
            id: "ISSUE-1", workspaceID: UUID(), title: "问题", aliases: [], background: "",
            rootCause: "", solution: "", status: "进行中", createdAt: Date(),
            updatedAt: Date(), sourceMeetingID: first.meetingID, events: [first])
        let analysis = ProjectIssueAnalysis(
            issueID: issue.id, workspaceID: issue.workspaceID, summary: "总结", timeline: [],
            generatedAt: Date(), sourceEventIDs: [first.id],
            analyzerVersion: ProjectIssueAnalysis.currentAnalyzerVersion)
        XCTAssertFalse(analysis.isStale(comparedWith: issue))
        XCTAssertFalse(analysis.needsAnalysisRefresh(comparedWith: issue))
        issue.events.append(ProjectIssueEvent(
            kind: .updated, occurredAt: Date(), meetingID: UUID(), meetingTitle: "后续会议",
            previousStatus: "进行中", currentStatus: "等待中", title: "问题", background: "",
            rootCause: "", solution: "", progress: "新增进展", evidence: ["屏幕 12:34"]))
        XCTAssertTrue(analysis.isStale(comparedWith: issue))
        XCTAssertTrue(analysis.needsAnalysisRefresh(comparedWith: issue))
    }

    func testAnalysisResponseParsesAndRemovesEvidenceTimecodes() throws {
        let raw = #"{"summary":"问题仍在排查。[12:34]","timeline":[{"date":"2026-08-01","meetingTitle":"周会","change":"已取得日志（[01:20]）"}]}"#
        let report = try ProjectIssueAnalysisService.parse(raw)
        XCTAssertEqual(report.summary, "问题仍在排查。")
        XCTAssertEqual(report.timeline.first?.change, "已取得日志")
        XCTAssertNil(report.timeline.first?.situation)
    }

    func testRichTimelineResponseParsesAllReadableFields() throws {
        let raw = #"{"summary":"问题完成验证。","timeline":[{"date":"2026-08-01","meetingTitle":"周会","stage":"验证","status":"已闭环","situation":"批处理仍需二十小时","change":"Hotfix 将处理恢复至目标速度","evidence":"680 万行约半小时完成 [01:20]","nextStep":"安排生产升级"}]}"#

        let item = try XCTUnwrap(ProjectIssueAnalysisService.parse(raw).timeline.first)

        XCTAssertEqual(item.stage, "验证")
        XCTAssertEqual(item.status, "已闭环")
        XCTAssertEqual(item.situation, "批处理仍需二十小时")
        XCTAssertEqual(item.change, "Hotfix 将处理恢复至目标速度")
        XCTAssertEqual(item.evidence, "680 万行约半小时完成")
        XCTAssertEqual(item.nextStep, "安排生产升级")
    }

    func testStructuredProfileSeparatesStableConclusionFromLatestProgress() throws {
        let raw = #"{"stableConclusion":"内核崩溃与组件冲突有明确历史证据。","latestProgress":"最新 UAT 已验证绕行方案。","unresolvedItems":["厂商根治版本尚未提供"],"nextSteps":["安排生产部署"],"diagnosticGuardrails":["未来新故障需重新采集日志"],"conclusionChanged":false,"conclusionChangeReason":"","timeline":[]}"#

        let report = try ProjectIssueAnalysisService.parse(raw)

        XCTAssertEqual(report.stableConclusion, "内核崩溃与组件冲突有明确历史证据。")
        XCTAssertEqual(report.latestProgress, "最新 UAT 已验证绕行方案。")
        XCTAssertEqual(report.unresolvedItems, ["厂商根治版本尚未提供"])
        XCTAssertEqual(report.nextSteps, ["安排生产部署"])
        XCTAssertEqual(report.diagnosticGuardrails, ["未来新故障需重新采集日志"])
        XCTAssertTrue(report.summary.contains("稳定结论："))
        XCTAssertTrue(report.summary.contains("最新进展："))
    }

    func testStructuredProfileParsesCauseToResultOverview() throws {
        let raw = #"{"overview":"批处理最初因引擎异常退出而变慢。对照测试后排除 Agent 是直接根因。各方最终确认为供应商引擎缺陷，当前不再安装 Agent，但引擎尚无修复计划。","stableConclusion":"供应商引擎缺陷是主因。","latestProgress":"问题已闭环。","timeline":[]}"#

        let report = try ProjectIssueAnalysisService.parse(raw)

        XCTAssertTrue(report.overview.contains("对照测试"))
        XCTAssertTrue(report.overview.contains("尚无修复计划"))
        XCTAssertEqual(report.stableConclusion, "供应商引擎缺陷是主因。")
    }

    func testLatestProgressRemovesInternalNoNewEventMessage() {
        let value = "UAT 已通过，等待生产排期。本次无新增事件，仅校正档案结构和表达。"

        XCTAssertEqual(
            ProjectIssueAnalysisService.userFacingLatestProgress(value),
            "UAT 已通过，等待生产排期。")
    }

    func testStableConclusionRemovesInternalEvidenceDefensePhrase() {
        let value = "根因是输入校验缺失，现场与本地均已复现，不能因后续会议未补充代码细节而否定既有定位。Hotfix尚未完成UAT验证。"

        XCTAssertEqual(
            ProjectIssueAnalysisService.userFacingStableConclusion(value),
            "根因是输入校验缺失，现场与本地均已复现。Hotfix尚未完成UAT验证。")
    }

    func testEstimatedTokensIsZeroWhenAnalysisAlreadyCoversAllEvents() {
        let event = ProjectIssueEvent(
            kind: .updated, occurredAt: Date(), meetingID: UUID(), meetingTitle: "周会",
            previousStatus: "进行中", currentStatus: "进行中", title: "问题",
            background: "", rootCause: "", solution: "", progress: "", evidence: [])
        let issue = ProjectIssue(
            id: "ISSUE-1", workspaceID: UUID(), title: "问题", aliases: [],
            background: "", rootCause: "", solution: "", status: "进行中",
            createdAt: Date(), updatedAt: Date(), sourceMeetingID: event.meetingID,
            events: [event])
        let previous = ProjectIssueAnalysis(
            issueID: issue.id, workspaceID: issue.workspaceID, summary: "旧总结",
            timeline: [], generatedAt: Date(), sourceEventIDs: [event.id],
            analyzerVersion: ProjectIssueAnalysis.currentAnalyzerVersion,
            stableConclusion: "已有稳定结论。")

        XCTAssertEqual(
            ProjectIssueAnalysisService.estimatedTokens(
                issue: issue, records: [], previousAnalysis: previous),
            0)
    }

    func testMatchingEventsStillRequireFullRebuildAfterAnalyzerUpgrade() {
        let event = ProjectIssueEvent(
            kind: .updated, occurredAt: Date(), meetingID: UUID(), meetingTitle: "周会",
            previousStatus: "进行中", currentStatus: "已闭环", title: "问题",
            background: "", rootCause: "", solution: "", progress: "", evidence: [])
        let issue = ProjectIssue(
            id: "ISSUE-1", workspaceID: UUID(), title: "问题", aliases: [],
            background: "", rootCause: "", solution: "", status: "已闭环",
            createdAt: Date(), updatedAt: Date(), sourceMeetingID: event.meetingID,
            events: [event])
        let legacy = ProjectIssueAnalysis(
            issueID: issue.id, workspaceID: issue.workspaceID, summary: "旧总结",
            timeline: [], generatedAt: Date(), sourceEventIDs: [event.id],
            stableConclusion: "旧版稳定结论。")

        XCTAssertFalse(legacy.isStale(comparedWith: issue))
        XCTAssertTrue(legacy.needsAnalysisRefresh(comparedWith: issue))
        XCTAssertGreaterThan(
            ProjectIssueAnalysisService.estimatedTokens(
                issue: issue, records: [], previousAnalysis: legacy),
            0)
    }

    func testIncrementalReportCannotReplaceStableConclusionWithoutReason() {
        let previous = ProjectIssueAnalysis(
            issueID: "ISSUE-1", workspaceID: UUID(), summary: "旧总结",
            timeline: [.init(
                date: "2026-08-01", meetingTitle: "首次会议", change: "定位冲突")],
            generatedAt: Date(), sourceEventIDs: [],
            overview: "历史全貌保留了最初现象和排查转折。",
            stableConclusion: "已有证据确认组件冲突。",
            latestProgress: "等待验证", unresolvedItems: ["等待 UAT"],
            nextSteps: ["执行 UAT"], diagnosticGuardrails: ["新现象重新取证"])
        let incoming = ProjectIssueAnalysisService.Report(
            summary: "", timeline: [.init(
                date: "2026-09-18", meetingTitle: "部署会议", change: "验证绕行方案",
                stage: "验证", status: "进行中", situation: nil,
                evidence: "UAT 通过", nextStep: "安排生产部署")],
            overview: "新版全貌保留排查转折，并补充 UAT 验证结果。",
            stableConclusion: "因为本次没有新日志，历史根因不成立。",
            latestProgress: "UAT 已通过", unresolvedItems: ["等待生产部署"],
            nextSteps: ["安排生产部署"],
            diagnosticGuardrails: ["新故障需要重新取证"],
            conclusionChanged: true, conclusionChangeReason: nil)

        let merged = ProjectIssueAnalysisService.mergeIncrementalReport(
            incoming, previous: previous)

        XCTAssertEqual(merged.stableConclusion, "已有证据确认组件冲突。")
        XCTAssertEqual(merged.overview, "新版全貌保留排查转折，并补充 UAT 验证结果。")
        XCTAssertFalse(merged.conclusionChanged)
        XCTAssertNil(merged.conclusionChangeReason)
        XCTAssertEqual(merged.timeline.count, 2)
        XCTAssertEqual(merged.timeline.last?.meetingTitle, "部署会议")
        XCTAssertEqual(merged.latestProgress, "UAT 已通过")
    }

    func testIncrementalReportAcceptsExplicitEvidenceBasedConclusionChange() {
        let previous = ProjectIssueAnalysis(
            issueID: "ISSUE-1", workspaceID: UUID(), summary: "旧总结", timeline: [],
            generatedAt: Date(), sourceEventIDs: [],
            stableConclusion: "初步判断为组件冲突。")
        let incoming = ProjectIssueAnalysisService.Report(
            summary: "", timeline: [], stableConclusion: "新证据确认是硬件故障。",
            conclusionChanged: true,
            conclusionChangeReason: "新增硬件自检日志明确显示内存错误。")

        let merged = ProjectIssueAnalysisService.mergeIncrementalReport(
            incoming, previous: previous)

        XCTAssertEqual(merged.stableConclusion, "新证据确认是硬件故障。")
        XCTAssertTrue(merged.conclusionChanged)
        XCTAssertEqual(merged.conclusionChangeReason, "新增硬件自检日志明确显示内存错误。")
    }

    func testMissingMeetingTitleIsRecoveredFromAssociatedEventByDate() throws {
        let occurredAt = Date(timeIntervalSince1970: 1_786_489_200)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: occurredAt)
        let event = ProjectIssueEvent(
            kind: .updated, occurredAt: occurredAt, meetingID: UUID(),
            meetingTitle: "星河银行终端安全技术同步", previousStatus: "进行中",
            currentStatus: "已闭环", title: "批处理变慢", background: "",
            rootCause: "扫描争用", solution: "防抖", progress: "验证通过", evidence: [])
        let raw = """
        {"summary":"问题已完成验证。","timeline":[{"date":"\(date)","stage":"闭环","status":"已闭环","situation":"等待验证","change":"性能恢复","evidence":"客户确认","nextStep":""}]}
        """

        let report = try ProjectIssueAnalysisService.parse(raw, fallbackEvents: [event])

        XCTAssertEqual(report.timeline.first?.meetingTitle, "星河银行终端安全技术同步")
        XCTAssertEqual(report.recoveredMeetingTitleCount, 1)
    }

    func testInvalidAnalysisReportsSpecificMissingField() {
        XCTAssertThrowsError(try ProjectIssueAnalysisService.parse(
            #"{"summary":"","timeline":[]}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("summary"))
        }
    }

    func testSourceMaterialIncludesOnlyAssociatedMeetingEvidenceContext() {
        let workspaceID = UUID()
        let associatedID = UUID()
        let unrelatedID = UUID()
        let event = ProjectIssueEvent(
            kind: .updated, occurredAt: Date(timeIntervalSince1970: 1_000),
            meetingID: associatedID, meetingTitle: "二月周会",
            previousStatus: "待确认", currentStatus: "进行中", title: "引擎崩溃",
            background: "批处理期间发生", rootCause: "仍在排查", solution: "收集日志",
            progress: "已取得错误码", evidence: ["屏幕 01:00"])
        let issue = ProjectIssue(
            id: "ISSUE-1", workspaceID: workspaceID, title: "引擎崩溃", aliases: [],
            background: "生产异常", rootCause: "待确认", solution: "继续取证", status: "进行中",
            createdAt: Date(), updatedAt: Date(), sourceMeetingID: associatedID, events: [event])
        let associated = meeting(id: associatedID, workspaceID: workspaceID,
                                 title: "二月周会", text: "错误码来自引擎内部")
        let unrelated = meeting(id: unrelatedID, workspaceID: workspaceID,
                                title: "无关会议", text: "这段内容不应进入分析")

        let material = ProjectIssueAnalysisService.sourceMaterial(
            issue: issue, records: [associated, unrelated])

        XCTAssertTrue(material.contains("二月周会"))
        XCTAssertTrue(material.contains("[01:00] 错误码来自引擎内部"))
        XCTAssertFalse(material.contains("无关会议"))
        XCTAssertFalse(material.contains("这段内容不应进入分析"))
    }

    private func meeting(id: UUID, workspaceID: UUID, title: String,
                         text: String) -> MeetingRecord {
        MeetingRecord(
            id: id, createdAt: Date(), title: title, sourcePath: "/meeting.mov",
            duration: 120, backend: "测试", model: "mock", summaryMarkdown: "",
            structuredSummary: nil,
            transcript: Transcript(segments: [
                TranscriptSegment(id: 0, start: 60, end: 65, text: text)
            ]), speakerNames: [:], usedSummaryFallback: false, workspaceID: workspaceID)
    }
}
