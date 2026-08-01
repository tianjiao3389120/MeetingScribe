import XCTest
@testable import MeetingScribe

final class StructuredMinutesTests: XCTestCase {
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
