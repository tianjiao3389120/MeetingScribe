import XCTest
@testable import MeetingScribe

final class WorkspaceMaterialTests: XCTestCase {
    func testActionTrackingSuggestsOnlyExactEvidenceBackedStatusChanges() {
        let workspaceID = UUID()
        let oldMinutes = StructuredMinutes(
            title: "上期", nature: "", duration: "", agenda: ["进展"],
            participantAssessment: [], issues: [], requirements: [],
            actionItems: [.init(owner: "张三", task: "提交上线方案", status: "进行中",
                                due: "", evidence: [])],
            agreements: [], afterMeeting: [], uncertainties: [])
        let old = MeetingRecord(
            title: "上期", sourcePath: "/old.mov", duration: 10,
            backend: "测试", model: "mock", summaryMarkdown: "纪要",
            structuredSummary: oldMinutes, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false, workspaceID: workspaceID)
        var current = StructuredMinutes(
            title: "本期", nature: "", duration: "", agenda: ["进展"],
            participantAssessment: [], issues: [], requirements: [],
            actionItems: [
                .init(owner: "张三", task: "提交上线方案", status: "已完成",
                      due: "", evidence: ["[08:20]"]),
                .init(owner: "李四", task: "确认名单", status: "已完成",
                      due: "", evidence: []),
            ], agreements: [], afterMeeting: [], uncertainties: [])

        let suggestions = ActionTracking.prepare(&current, priorRecords: [old])
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].task, "提交上线方案")
        XCTAssertEqual(suggestions[0].proposedStatus, "已完成")
        XCTAssertEqual(current.actionItems[0].trackingID, suggestions[0].targetActionID)
        XCTAssertNotNil(current.actionItems[1].trackingID)
    }
    func testWorkspaceRoundTripPreservesContext() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-workspaces-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var workspace = MeetingWorkspace(name: "某客户", kind: .customer,
                                         context: "我方是安全产品厂商")
        workspace.defaultTemplateID = MinutesTemplate.customer.id
        workspace.defaultEmailTemplateID = EmailTemplate.customer.id

        try MeetingWorkspaceStore.save([workspace], to: url)
        let loaded = try MeetingWorkspaceStore.load(from: url)
        XCTAssertEqual(loaded.first?.id, workspace.id)
        XCTAssertEqual(loaded.first?.context, "我方是安全产品厂商")
        XCTAssertEqual(loaded.first?.defaultTemplateID, MinutesTemplate.customer.id)
        XCTAssertEqual(loaded.first?.defaultEmailTemplateID, EmailTemplate.customer.id)
    }

    func testTextMaterialExtractionAndLengthLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("material-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try String(repeating: "材料", count: 10_000).write(
            to: url, atomically: true, encoding: .utf8)

        let material = try MaterialExtractor.extract(from: url)
        XCTAssertEqual(material.kind, .text)
        XCTAssertEqual(material.extractedText.count, MaterialExtractor.perFileCharacterLimit)
    }

    func testUnsupportedMaterialIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("material.docx")
        XCTAssertThrowsError(try MaterialExtractor.extract(from: url))
    }

    @MainActor
    func testHongKongScenarioUsesAutomaticLanguageAndMaterialTerms() {
        let material = SupportingMaterial(
            sourceURL: URL(fileURLWithPath: "/tmp/Project Atlas.md"),
            kind: .text,
            extractedText: "Client 要确认 Falcon Gateway 的 deployment timeline。")
        let prompt = PipelineRunner.transcriptionPrompt(
            scenario: .hongKongMixed,
            glossary: "通用词表",
            materials: [material])
        let trimmed = Transcriber.trimGlossary(prompt)

        XCTAssertEqual(RecognitionScenario.hongKongMixed.whisperLanguage, "auto")
        XCTAssertTrue(trimmed.contains("香港粤语"))
        XCTAssertTrue(trimmed.contains("Falcon Gateway"))
        XCTAssertTrue(RecognitionScenario.hongKongMixed.analysisGuidance.contains("简体书面中文"))
    }

    func testWorkspaceInsightsAggregatesOpenAndClosedActions() {
        func record(status: String, task: String) -> MeetingRecord {
            let minutes = StructuredMinutes(
                title: "周会", nature: "", duration: "", agenda: ["进展"],
                participantAssessment: [], issues: [], requirements: [],
                actionItems: [.init(owner: "张三", task: task, status: status,
                                    due: "周五", evidence: ["[01:00]"])],
                agreements: [], afterMeeting: [], uncertainties: [])
            return MeetingRecord(
                title: "项目周会", sourcePath: "/meeting.mov", duration: 60,
                backend: "测试", model: "mock", summaryMarkdown: "纪要",
                structuredSummary: minutes, transcript: Transcript(segments: []),
                speakerNames: [:], usedSummaryFallback: false)
        }

        let insights = WorkspaceInsights(records: [
            record(status: "进行中", task: "提交方案"),
            record(status: "已完成", task: "确认名单"),
        ])
        XCTAssertEqual(insights.actions.count, 2)
        XCTAssertEqual(insights.openActions.map(\.task), ["提交方案"])
        XCTAssertEqual(insights.closedActions.map(\.task), ["确认名单"])
    }

    func testWorkspaceInsightsKeepsLatestActionStateWithoutDuplicatingLedger() {
        func record(date: Date, status: String) -> MeetingRecord {
            let minutes = StructuredMinutes(
                title: "周会", nature: "", duration: "", agenda: ["进展"],
                participantAssessment: [], issues: [], requirements: [],
                actionItems: [.init(owner: "张三", task: "提交实施方案", status: status,
                                    due: "周五", evidence: [])],
                agreements: [], afterMeeting: [], uncertainties: [])
            return MeetingRecord(createdAt: date, title: "项目周会", sourcePath: "/meeting.mov",
                                 duration: 60, backend: "测试", model: "mock",
                                 summaryMarkdown: "纪要", structuredSummary: minutes,
                                 transcript: Transcript(segments: []), speakerNames: [:],
                                 usedSummaryFallback: false)
        }

        let insights = WorkspaceInsights(records: [
            record(date: Date(timeIntervalSince1970: 100), status: "进行中"),
            record(date: Date(timeIntervalSince1970: 200), status: "已完成"),
        ])
        XCTAssertEqual(insights.actions.count, 2)
        XCTAssertTrue(insights.openActions.isEmpty)
        XCTAssertEqual(insights.closedActions.count, 1)
        XCTAssertEqual(insights.closedActions.first?.status, "已完成")
        XCTAssertFalse(WorkspaceInsights.isClosed(status: "未完成"))
        XCTAssertFalse(WorkspaceInsights.isClosed(status: "待解决"))
        XCTAssertTrue(WorkspaceInsights.isClosed(status: "已解决"))
    }

    func testWorkspaceInsightsComparesLatestMeetingsWithoutTreatingOmissionAsClosed() throws {
        func record(date: Date, issues: [StructuredMinutes.Issue],
                    requirements: [StructuredMinutes.Requirement],
                    actions: [StructuredMinutes.ActionItem]) -> MeetingRecord {
            let minutes = StructuredMinutes(
                title: "双周会", nature: "", duration: "", agenda: ["进展"],
                participantAssessment: [], issues: issues, requirements: requirements,
                actionItems: actions, agreements: [], afterMeeting: [], uncertainties: [])
            return MeetingRecord(createdAt: date, title: "双周会", sourcePath: "/meeting.mov",
                                 duration: 60, backend: "测试", model: "mock",
                                 summaryMarkdown: "纪要", structuredSummary: minutes,
                                 transcript: Transcript(segments: []), speakerNames: [:],
                                 usedSummaryFallback: false)
        }

        let old = record(
            date: Date(timeIntervalSince1970: 100),
            issues: [
                .init(title: "登录超时", status: "处理中", rootCause: "", solution: "",
                      progress: "", evidence: []),
                .init(title: "报表错误", status: "处理中", rootCause: "", solution: "",
                      progress: "", evidence: []),
            ],
            requirements: [],
            actions: [.init(owner: "李四", task: "确认上线窗口", status: "未开始",
                            due: "", evidence: [])])
        let current = record(
            date: Date(timeIntervalSince1970: 200),
            issues: [
                .init(title: "登录超时", status: "已解决", rootCause: "", solution: "",
                      progress: "", evidence: []),
                .init(title: "新增告警", status: "处理中", rootCause: "", solution: "",
                      progress: "", evidence: []),
            ],
            requirements: [.init(title: "增加审计报表", status: "待评估", schedule: "",
                                 evidence: [])],
            actions: [.init(owner: "李四", task: "确认上线窗口", status: "进行中",
                            due: "", evidence: [])])

        let changes = try XCTUnwrap(WorkspaceInsights(records: [old, current]).latestChanges)
        XCTAssertEqual(changes.currentMeeting.createdAt, current.createdAt)
        XCTAssertEqual(changes.items(of: .closed).map(\.title), ["登录超时"])
        XCTAssertEqual(Set(changes.items(of: .new).map(\.title)), ["新增告警", "增加审计报表"])
        XCTAssertEqual(changes.items(of: .statusChanged).map(\.title), ["确认上线窗口"])
        XCTAssertEqual(changes.items(of: .notMentioned).map(\.title), ["报表错误"])
    }
}
