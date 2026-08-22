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

    func testHongKongMinutesPromptLocalizesWithoutChangingFacts() {
        let prompt = HongKongMinutesGenerator.systemPrompt
        XCTAssertTrue(prompt.contains("不是简单的简体转繁体"))
        XCTAssertTrue(prompt.contains("香港常见的繁体中文书面语"))
        XCTAssertTrue(prompt.contains("保留 Markdown"))
        XCTAssertTrue(prompt.contains("事实、数字、日期、时间、责任人"))
        XCTAssertTrue(prompt.contains("不得添加、删除、推断或弱化"))
    }

    func testMinutesTemplatesMapToExpectedEmailTemplates() {
        XCTAssertEqual(EmailTemplate.defaultID(forMinutesTemplateID: MinutesTemplate.biweekly.id),
                       EmailTemplate.progress.id)
        XCTAssertEqual(EmailTemplate.defaultID(forMinutesTemplateID: MinutesTemplate.customer.id),
                       EmailTemplate.customer.id)
        XCTAssertEqual(EmailTemplate.defaultID(forMinutesTemplateID: MinutesTemplate.incident.id),
                       EmailTemplate.incident.id)
        XCTAssertEqual(Set(EmailTemplate.all.map(\.id)).count, EmailTemplate.all.count)
    }
}
