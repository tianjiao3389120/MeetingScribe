import XCTest
@testable import MeetingScribe

final class RenderingTests: XCTestCase {
    func testMarkdownEscapesRawHTMLAndRendersSupportedBlocks() {
        let html = MarkdownRenderer.body(from: """
        # 标题 <script>

        - [x] 已完成

        | 项目 | 状态 |
        | --- | --- |
        | A | [进行中] |
        """)

        XCTAssertTrue(html.contains("<h1>标题 &lt;script&gt;</h1>"))
        XCTAssertTrue(html.contains("type=\"checkbox\" checked"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("class=\"tag\">进行中</span>"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testGlossaryDropsCommentsAndCapsLength() {
        let raw = "# comment\n" + String(repeating: "术", count: 200)
        XCTAssertEqual(Transcriber.trimGlossary(raw).count, 170)
        XCTAssertFalse(Transcriber.trimGlossary(raw).contains("comment"))
    }
}
