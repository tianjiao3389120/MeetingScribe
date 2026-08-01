import XCTest
@testable import MeetingScribe

final class TranscriptTests: XCTestCase {
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

    func testTimeAndDurationFormatting() {
        XCTAssertEqual(TranscriptSegment.timecode(-3), "00:00")
        XCTAssertEqual(TranscriptSegment.timecode(3661), "1:01:01")
        XCTAssertEqual(TranscriptSegment.humanDuration(45), "45 秒")
        XCTAssertEqual(TranscriptSegment.humanDuration(125), "2 分 5 秒")
        XCTAssertEqual(TranscriptSegment.humanDuration(3660), "1 小时 1 分钟")
    }
}
