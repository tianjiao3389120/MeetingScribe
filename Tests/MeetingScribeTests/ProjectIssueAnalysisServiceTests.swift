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
        let second = ProjectIssueAnalysisService.Report(summary: "第二版", timeline: [])
        _ = try ProjectLedgerStore.saveIssueAnalysis(issue: issue, report: first, at: url)
        _ = try ProjectLedgerStore.saveIssueAnalysis(issue: issue, report: second, at: url)
        let loaded = try ProjectLedgerStore.load(from: url)

        XCTAssertEqual(loaded.issueAnalyses.count, 1)
        XCTAssertEqual(loaded.analysis(for: issue.id)?.summary, "第二版")
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
            generatedAt: Date(), sourceEventIDs: [first.id])
        XCTAssertFalse(analysis.isStale(comparedWith: issue))
        issue.events.append(ProjectIssueEvent(
            kind: .updated, occurredAt: Date(), meetingID: UUID(), meetingTitle: "后续会议",
            previousStatus: "进行中", currentStatus: "等待中", title: "问题", background: "",
            rootCause: "", solution: "", progress: "新增进展", evidence: ["屏幕 12:34"]))
        XCTAssertTrue(analysis.isStale(comparedWith: issue))
    }

    func testAnalysisResponseParsesAndRemovesEvidenceTimecodes() throws {
        let raw = #"{"summary":"问题仍在排查。[12:34]","timeline":[{"date":"2026-08-01","meetingTitle":"周会","change":"已取得日志（[01:20]）"}]}"#
        let report = try ProjectIssueAnalysisService.parse(raw)
        XCTAssertEqual(report.summary, "问题仍在排查。")
        XCTAssertEqual(report.timeline.first?.change, "已取得日志")
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
