import XCTest
@testable import MeetingScribe

final class TokenUsageLedgerTests: XCTestCase {
    func testLedgerPersistsDetailedAttributionAndFailureStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root.appendingPathComponent("usage.json")
        let meetingID = UUID()
        let entry = TokenUsageEntry(
            id: UUID(), startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 11), feature: "项目问题分析",
            customer: "客户甲", project: "项目乙", meetingID: meetingID,
            meetingTitle: "周会", backend: "OpenAI", model: "gpt-test",
            inputTokens: 1200, outputTokens: 300, isEstimated: false,
            status: .failed, errorMessage: "中断")

        TokenUsageLedger.append(entry, to: url)

        XCTAssertEqual(TokenUsageLedger.load(from: url), [entry])
        XCTAssertEqual(TokenUsageLedger.load(from: url).first?.totalTokens, 1500)
    }

    func testMeetingEstimateIncludesVisionAndMaterials() {
        let plain = TokenBudgetEstimator.meeting(
            duration: 3600, materialText: "", includesVision: false, frameDensity: .off)
        let rich = TokenBudgetEstimator.meeting(
            duration: 3600, materialText: String(repeating: "材料", count: 1000),
            includesVision: true, frameDensity: .normal)
        XCTAssertGreaterThan(rich, plain)
        XCTAssertGreaterThan(plain, 10_000)
    }
}
