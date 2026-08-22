import XCTest
@testable import MeetingScribe

final class StructuredMinutesTests: XCTestCase {
    func testTokenEstimatorAndUsageTotals() {
        let phase = GenerationUsage.estimatedPhase(
            name: "主纪要", input: "会议内容 ABCD", output: "会议纪要")
        let usage = GenerationUsage(phases: [phase], isEstimated: true)
        XCTAssertGreaterThan(usage.inputTokens, 0)
        XCTAssertGreaterThan(usage.outputTokens, 0)
        XCTAssertEqual(usage.totalTokens, usage.inputTokens + usage.outputTokens)
        XCTAssertEqual(usage.calls, 1)
    }

    func testApplicationTokenUsageAggregatesByModel() {
        let transcript = Transcript(segments: [])
        var first = MeetingRecord(title: "A", sourcePath: "/a", duration: 1,
                                  backend: "本机", model: "Codex CLI", summaryMarkdown: "",
                                  structuredSummary: nil, transcript: transcript,
                                  speakerNames: [:], usedSummaryFallback: false)
        first.generationUsage = GenerationUsage(
            phases: [.init(name: "主纪要", inputTokens: 100, outputTokens: 20, calls: 1)],
            isEstimated: true)
        var second = MeetingRecord(title: "B", sourcePath: "/b", duration: 1,
                                   backend: "本机", model: "Codex CLI", summaryMarkdown: "",
                                   structuredSummary: nil, transcript: transcript,
                                   speakerNames: [:], usedSummaryFallback: false)
        second.generationUsage = GenerationUsage(
            phases: [.init(name: "主纪要", inputTokens: 50, outputTokens: 10, calls: 1)],
            isEstimated: true)

        let rows = ApplicationTokenUsage.aggregate([first, second])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].inputTokens, 150)
        XCTAssertEqual(rows[0].outputTokens, 30)
        XCTAssertEqual(rows[0].totalTokens, 180)
        XCTAssertEqual(rows[0].meetings, 2)
    }

    func testMeetingDateUsesRecordingFileCreationDate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-date-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: expected,
                                               .modificationDate: expected.addingTimeInterval(60)],
                                              ofItemAtPath: url.path)
        XCTAssertEqual(MeetingDateResolver.recordedAt(for: url).timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 1)
    }

    func testGeneratedMeetingTitleReplacesOnlyDefaultFilename() {
        let source = URL(fileURLWithPath: "/tmp/Screen Recording 2026-08-08.mov")

        XCTAssertEqual(MeetingTitleResolver.resolve(
            requestedTitle: "Screen Recording 2026-08-08", sourceURL: source,
            generatedTitle: "中银香港 HIDS 阶段进展双周会"),
            "中银香港 HIDS 阶段进展双周会")
        XCTAssertEqual(MeetingTitleResolver.resolve(
            requestedTitle: "我手动设置的周会", sourceURL: source,
            generatedTitle: "模型生成的名称"),
            "我手动设置的周会")
    }

    func testHistoricalTitleUsesExistingStructuredTitleWithoutOverwritingManualName() {
        let minutes = StructuredMinutes(
            title: "中银香港 HIDS 阶段工作同步", nature: "双周会", duration: "30 分钟",
            agenda: ["进度同步"], participantAssessment: [], issues: [], requirements: [],
            actionItems: [], agreements: [], afterMeeting: [], uncertainties: [])
        var record = MeetingRecord(
            title: "录屏 2026-08-01", sourcePath: "/录屏 2026-08-01.mov", duration: 1,
            backend: "测试", model: "mock", summaryMarkdown: "纪要",
            structuredSummary: minutes, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false)
        XCTAssertEqual(MeetingTitleResolver.historicalTitle(for: record),
                       "中银香港 HIDS 阶段工作同步")
        record.title = "我手动设置的名称"
        XCTAssertNil(MeetingTitleResolver.historicalTitle(for: record))
    }

    func testGeneratedMeetingTitleRejectsGenericAndCleansDecoration() {
        let source = URL(fileURLWithPath: "/tmp/recording.mp4")

        XCTAssertEqual(MeetingTitleResolver.resolve(
            requestedTitle: "recording", sourceURL: source, generatedTitle: "会议纪要"),
            "recording")
        XCTAssertEqual(MeetingTitleResolver.resolve(
            requestedTitle: "recording", sourceURL: source,
            generatedTitle: "标题：**日志治理方案评审与上线安排**\n补充说明"),
            "日志治理方案评审与上线安排")
    }

    private let json = #"""
    {
      "title":"会议纪要","nature":"双周会","duration":"40 分钟",
      "agenda":["问题复盘","上线安排"],"participantAssessment":[],
      "issues":[{"title":"日志积压","status":"进行中","rootCause":"处理能力不足","solution":"扩容","progress":"验证中","evidence":["[12:34]"]}],
      "requirements":[{"title":"增加告警导出","status":"待确认","schedule":"下周","evidence":[]}],
      "actionItems":[{"owner":"张三","task":"提交方案","status":"进行中","due":"周五","evidence":["[20:00]"]}],
      "agreements":[{"content":"邮件抄送安全团队","evidence":["[22:00]"]}],
      "afterMeeting":[],"uncertainties":[]
    }
    """#

    func testParsesPlainAndFencedJSON() {
        XCTAssertNotNil(Analyzer.parseStructured(json))
        XCTAssertNotNil(Analyzer.parseStructured("```json\n\(json)\n```"))
        XCTAssertNotNil(Analyzer.parseStructured("以下是结果：\n\(json)\n结束"))
    }

    func testRejectsEmptyOrMalformedPayload() {
        XCTAssertNil(Analyzer.parseStructured("not json"))
        XCTAssertNil(Analyzer.parseStructured(#"{"title":"会议纪要"}"#))
    }

    func testRendersDeterministicMarkdownWithEvidence() throws {
        let value = try XCTUnwrap(Analyzer.parseStructured(json))
        let markdown = StructuredMinutesRenderer.markdown(from: value)

        XCTAssertTrue(markdown.contains("# 会议纪要"))
        XCTAssertTrue(markdown.contains("**性质**：双周会  \n**时长**：40 分钟\n\n**议程**：\n1. 问题复盘\n2. 上线安排"))
        let html = MarkdownRenderer.body(from: markdown)
        XCTAssertTrue(html.contains("<strong>性质</strong>：双周会<br><strong>时长</strong>：40 分钟"))
        XCTAssertTrue(html.contains("<p><strong>议程</strong>：</p><ol><li>问题复盘</li><li>上线安排</li></ol>"))
        XCTAssertTrue(markdown.contains("### 日志积压 [进行中]"))
        XCTAssertTrue(markdown.contains("- [ ] 提交方案（周五） [进行中]（证据：[20:00]）"))
        XCTAssertTrue(markdown.contains("### 协作约定"))
    }

    func testMinutesShowOnlyFormalMeetingDuration() throws {
        var value = try XCTUnwrap(Analyzer.parseStructured(json))
        value.duration = "录制时长1小时6分钟；正式会议约1小时3分30秒"

        let internalMarkdown = StructuredMinutesRenderer.markdown(from: value)
        let meetingMarkdown = CustomerMinutesRenderer.markdown(from: value)

        XCTAssertTrue(internalMarkdown.contains("**时长**：约1小时3分30秒"))
        XCTAssertTrue(meetingMarkdown.contains("**时长**：约1小时3分30秒"))
        XCTAssertFalse(internalMarkdown.contains("录制时长"))
        XCTAssertFalse(meetingMarkdown.contains("录制时长"))
    }

    func testExistingRecordRendersFromStructuredMinutesInsteadOfStaleMarkdown() throws {
        let value = try XCTUnwrap(Analyzer.parseStructured(json))
        let record = MeetingRecord(
            title: "旧会议", sourcePath: "/meeting.mov", duration: 60,
            backend: "测试", model: "mock", summaryMarkdown: "旧版连行内容",
            structuredSummary: value, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false)

        let markdown = StructuredMinutesRenderer.markdown(for: record)

        XCTAssertFalse(markdown.contains("旧版连行内容"))
        XCTAssertTrue(markdown.contains("**议程**：\n1. 问题复盘\n2. 上线安排"))
    }

    func testCustomerMinutesHideInternalSectionsAndAllEvidence() throws {
        var value = try XCTUnwrap(Analyzer.parseStructured(json))
        value.participantAssessment = ["张三负责内部决策"]
        value.afterMeeting = [.init(content: "客户离开后的内部讨论", evidence: ["[35:00]"])]
        value.uncertainties = [.init(content: "名称可能识别错误", evidence: ["[08:00]"])]

        let markdown = CustomerMinutesRenderer.markdown(from: value)

        XCTAssertTrue(markdown.contains("日志积压"))
        XCTAssertTrue(markdown.contains("增加告警导出"))
        XCTAssertTrue(markdown.contains("提交方案"))
        XCTAssertFalse(markdown.contains("参会角色判断"))
        XCTAssertFalse(markdown.contains("张三负责内部决策"))
        XCTAssertFalse(markdown.contains("会后（非正式内容）"))
        XCTAssertFalse(markdown.contains("客户离开后的内部讨论"))
        XCTAssertFalse(markdown.contains("名称可能识别错误"))
        XCTAssertFalse(markdown.contains("证据"))
        XCTAssertFalse(markdown.contains("[12:34]"))
        XCTAssertFalse(markdown.contains("[20:00]"))
    }
}
