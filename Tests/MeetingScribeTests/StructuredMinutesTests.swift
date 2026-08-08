import XCTest
@testable import MeetingScribe

final class StructuredMinutesTests: XCTestCase {
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
      "agenda":["问题复盘"],"participantAssessment":[],
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
        XCTAssertTrue(markdown.contains("### 日志积压 [进行中]"))
        XCTAssertTrue(markdown.contains("- [ ] 提交方案（周五） [进行中]（证据：[20:00]）"))
        XCTAssertTrue(markdown.contains("### 协作约定"))
    }
}
