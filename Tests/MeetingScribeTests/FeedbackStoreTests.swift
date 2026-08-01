import XCTest
@testable import MeetingScribe

final class FeedbackStoreTests: XCTestCase {
    func testFeedbackAndCandidatesRoundTripWithoutAutomaticGlossaryMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-feedback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID()
        let feedback = MeetingFeedback(
            meetingID: meetingID, rating: .needsImprovement,
            issues: [.terminology], notes: "产品名识别错误")

        try FeedbackStore.save(feedback, root: root)
        let loaded = try XCTUnwrap(FeedbackStore.load(meetingID: meetingID, root: root))
        XCTAssertEqual(loaded.meetingID, feedback.meetingID)
        XCTAssertEqual(loaded.rating, feedback.rating)
        XCTAssertEqual(loaded.issues, feedback.issues)
        XCTAssertEqual(loaded.notes, feedback.notes)

        let candidatesURL = root.appendingPathComponent("candidates.json")
        try FeedbackStore.addCandidates(
            ["MeetingScribe", "MeetingScribe", " UAT "],
            meetingID: meetingID, title: "客户会议", to: candidatesURL)
        let candidates = FeedbackStore.loadCandidates(from: candidatesURL)
        XCTAssertEqual(Set(candidates.map(\.term)), ["MeetingScribe", "UAT"])
        try FeedbackStore.removeCandidate(id: candidates[0].id, from: candidatesURL)
        XCTAssertEqual(FeedbackStore.loadCandidates(from: candidatesURL).count, 1)
    }

    func testMinutesTemplatesHaveStableUniqueIDs() {
        XCTAssertEqual(Set(MinutesTemplate.all.map(\.id)).count, MinutesTemplate.all.count)
        XCTAssertEqual(MinutesTemplate.template(id: "missing"), .general)
        XCTAssertTrue(MinutesTemplate.all.allSatisfy { !$0.instructions.isEmpty })
    }

    func testEmailPromptsPreserveFactsAndRequireChineseReviewFirst() {
        let chinese = MeetingEmailGenerator.chineseSystemPrompt(tone: .formal, audience: .customer)
        XCTAssertTrue(chinese.contains("只使用纪要中的事实"))
        XCTAssertTrue(chinese.contains("客户"))
        XCTAssertTrue(chinese.contains("一、整体总结"))
        XCTAssertTrue(chinese.contains("二、问题与故障"))
        XCTAssertTrue(chinese.contains("根因、方案、验证、下一步"))
        XCTAssertTrue(chinese.contains("三、需求"))
        XCTAssertTrue(chinese.contains("不要 Markdown 表格"))
        XCTAssertTrue(MeetingEmailGenerator.hongKongSystemPrompt.contains("已经确认"))
        XCTAssertTrue(MeetingEmailGenerator.hongKongSystemPrompt.contains("不得增加或删除承诺"))
    }
}
