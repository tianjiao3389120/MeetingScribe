import XCTest
@testable import MeetingScribe

final class TranscriptTests: XCTestCase {
    func testEditedTranscriptPreservesTimingAndRejectsChangedLineCount() {
        let original = Transcript(segments: [
            TranscriptSegment(id: 0, start: 1, end: 2, text: "旧内容"),
            TranscriptSegment(id: 1, start: 3, end: 4, text: "第二句"),
        ])
        let edited = original.replacingTexts(from: "[00:01] 新内容\n[00:03] 修正版")
        XCTAssertEqual(edited?.segments.map(\.text), ["新内容", "修正版"])
        XCTAssertEqual(edited?.segments[0].start, 1)
        XCTAssertNil(original.replacingTexts(from: "只有一行"))
    }

    func testTranslationResponseParsesFencedJSONAndPreservesIDs() throws {
        let raw = """
        ```json
        [{"id":0,"text":"这个功能需要客户确认。"},{"id":1,"text":"明天更新 timeline。"}]
        ```
        """
        let values = try TranscriptTranslator.parseResponse(raw)
        XCTAssertEqual(values.map(\.segmentID), [0, 1])
        XCTAssertEqual(values[0].text, "这个功能需要客户确认。")
        XCTAssertThrowsError(try TranscriptTranslator.parseResponse("不是 JSON"))
    }

    func testParsesMultilineSRTAndSkipsMalformedBlocks() {
        let transcript = Transcript.parse(srt: """
        1
        00:00:01,250 --> 00:00:03,500
        第一行
        第二行

        broken
        block

        2
        01:02:03.400 --> 01:02:05.000
        final
        """)

        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].text, "第一行 第二行")
        XCTAssertEqual(transcript.segments[0].start, 1.25, accuracy: 0.001)
        XCTAssertEqual(transcript.segments[1].start, 3723.4, accuracy: 0.001)
    }

    func testMiaojiiSRTParsesSpeakerWithoutKeepingPrefixInText() {
        let transcript = Transcript.parse(srt: """
        1
        00:00:02,640 --> 00:00:13,840
        说话人 1: It has conducted a detection test.

        2
        00:00:14,720 --> 00:00:24,920
        邓亚琛: Have you tested the detection rate?
        """)

        XCTAssertEqual(transcript.segments.map(\.speaker), ["说话人 1", "邓亚琛"])
        XCTAssertEqual(transcript.segments[0].text, "It has conducted a detection test.")
        XCTAssertTrue(transcript.timecodedText.contains("【邓亚琛】Have you tested"))

        let edited = transcript.replacingTexts(from: transcript.timecodedText)
        XCTAssertEqual(edited?.segments[0].speaker, "说话人 1")
        XCTAssertEqual(edited?.segments[0].text, "It has conducted a detection test.")
    }

    func testMiaojiiTextMetadataParsesDateDurationAndKeywords() {
        let metadata = ExternalTranscriptMetadata.parseMiaojii("""
        2026年8月13日 上午 10:07|50分钟 35秒

        关键词:
        new market、customer price、Malaysia market

        文字记录:
        """)

        XCTAssertEqual(metadata.declaredDuration, 3035)
        XCTAssertEqual(metadata.keywords, ["new market", "customer price", "Malaysia market"])
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute], from: try! XCTUnwrap(metadata.recordedAt))
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 13)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 7)
    }

    func testLegacyTranscriptDecodesWithoutSpeakerField() throws {
        let data = #"{"segments":[{"id":0,"start":1,"end":2,"text":"旧记录"}]}"#.data(using: .utf8)!
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)
        XCTAssertNil(transcript.segments[0].speaker)
    }

    func testTimeAndDurationFormatting() {
        XCTAssertEqual(TranscriptSegment.timecode(-3), "00:00")
        XCTAssertEqual(TranscriptSegment.timecode(3661), "1:01:01")
        XCTAssertEqual(TranscriptSegment.humanDuration(45), "45 秒")
        XCTAssertEqual(TranscriptSegment.humanDuration(125), "2 分 5 秒")
        XCTAssertEqual(TranscriptSegment.humanDuration(3660), "1 小时 1 分钟")
    }
}
