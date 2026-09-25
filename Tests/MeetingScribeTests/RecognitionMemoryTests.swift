import XCTest
@testable import MeetingScribe

final class RecognitionMemoryTests: XCTestCase {
    func testProjectMemoryRanksAheadOfGlobalMemory() throws {
        let url = temporaryURL()
        let project = UUID()
        try RecognitionMemoryStore.save([
            RecognitionMemoryEntry(canonical: "全局术语"),
            RecognitionMemoryEntry(canonical: "项目术语", workspaceID: project)
        ], to: url)
        let result = RecognitionMemoryStore.relevant(workspaceID: project, from: url)
        XCTAssertEqual(result.first?.canonical, "项目术语")
    }

    func testCustomerMemoryIsInheritedByItsProjectsOnly() throws {
        let url = temporaryURL()
        let customer = MeetingWorkspace(name: "星河银行", kind: .customer)
        let project = MeetingWorkspace(
            name: "终端安全", kind: .project, customerID: customer.id)
        let otherCustomer = MeetingWorkspace(name: "其他客户", kind: .customer)
        try RecognitionMemoryStore.save([
            RecognitionMemoryEntry(canonical: "全局词"),
            RecognitionMemoryEntry(canonical: "客户专家甲", kind: .person, workspaceID: customer.id),
            RecognitionMemoryEntry(canonical: "项目词", workspaceID: project.id),
            RecognitionMemoryEntry(canonical: "其他客户词", workspaceID: otherCustomer.id)
        ], to: url)

        let result = RecognitionMemoryStore.relevant(
            workspaceID: project.id, from: url,
            workspaces: [customer, project, otherCustomer])

        XCTAssertEqual(result.map(\.canonical), ["项目词", "客户专家甲", "全局词"])
    }

    func testConfirmedCorrectionUsesLatinBoundaries() throws {
        let url = temporaryURL()
        try RecognitionMemoryStore.save([
            RecognitionMemoryEntry(mistaken: "codex", canonical: "Codex CLI")
        ], to: url)
        let source = Transcript(segments: [
            TranscriptSegment(id: 0, start: 0, end: 1, text: "codex 和 codexample")
        ])
        let result = RecognitionMemoryStore.apply(to: source, workspaceID: nil, from: url)
        XCTAssertEqual(result.plainText, "Codex CLI 和 codexample")
        XCTAssertEqual(RecognitionMemoryStore.load(from: url).first?.usageCount, 1)
    }

    func testDetailedCorrectionReportsEveryReplacement() throws {
        let url = temporaryURL()
        try RecognitionMemoryStore.save([
            RecognitionMemoryEntry(mistaken: "客户专家家", canonical: "客户专家甲", kind: .person)
        ], to: url)
        let source = Transcript(segments: [
            TranscriptSegment(id: 0, start: 0, end: 1, text: "谢谢客户专家家，客户专家家再见")
        ])

        let result = RecognitionMemoryStore.applyDetailed(
            to: source, workspaceID: nil, from: url)

        XCTAssertEqual(result.transcript.plainText, "谢谢客户专家甲，客户专家甲再见")
        XCTAssertEqual(result.corrections, [
            .init(mistaken: "客户专家家", canonical: "客户专家甲", count: 2)
        ])
        XCTAssertTrue(result.logDescription.contains("2 处"))
    }

    func testPromptUsageIsTrackedSeparatelyFromCorrections() throws {
        let url = temporaryURL()
        try RecognitionMemoryStore.save([
            RecognitionMemoryEntry(canonical: "张三", kind: .person)
        ], to: url)

        RecognitionMemoryStore.recordPromptUsage(workspaceID: nil, from: url)
        let entry = try XCTUnwrap(RecognitionMemoryStore.load(from: url).first)
        XCTAssertEqual(entry.promptUsageCount, 1)
        XCTAssertEqual(entry.usageCount, 0)
    }

    func testPromptInterpolatesCorrectionValues() throws {
        let url = temporaryURL()
        try RecognitionMemoryStore.save([
            RecognitionMemoryEntry(mistaken: "星盾诶", canonical: "星盾AI")
        ], to: url)
        let prompt = RecognitionMemoryStore.prompt(workspaceID: nil, from: url)
        XCTAssertEqual(prompt, "星盾AI")
        XCTAssertFalse(prompt.contains("$0"))
    }

    func testWhisperPromptDeduplicatesCanonicalWordAcrossCorrectionVariants() throws {
        let url = temporaryURL()
        try RecognitionMemoryStore.save([
            RecognitionMemoryEntry(mistaken: "星盾诶", canonical: "星盾AI"),
            RecognitionMemoryEntry(mistaken: "星盾爱", canonical: "星盾AI"),
            RecognitionMemoryEntry(mistaken: "星盾 A I", canonical: "星盾AI")
        ], to: url)

        XCTAssertEqual(RecognitionMemoryStore.prompt(workspaceID: nil, from: url), "星盾AI")
        RecognitionMemoryStore.recordPromptUsage(workspaceID: nil, from: url)
        XCTAssertEqual(RecognitionMemoryStore.load(from: url)
            .filter { ($0.promptUsageCount ?? 0) > 0 }.count, 1)
    }

    func testEditingMemoryReplacesRecordAndPreservesUsageHistory() throws {
        let url = temporaryURL()
        var original = RecognitionMemoryEntry(
            mistaken: "星盾诶", canonical: "星盾AI", usageCount: 3,
            promptUsageCount: 4)
        try RecognitionMemoryStore.save([original], to: url)

        original.mistaken = "无线 AI"
        original.kind = .product
        original.isEnabled = false
        let updated = try RecognitionMemoryStore.update(original, in: url)
        let values = RecognitionMemoryStore.load(from: url)

        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(updated.mistaken, "无线 AI")
        XCTAssertEqual(updated.kind, .product)
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.usageCount, 3)
        XCTAssertEqual(updated.promptUsageCount, 4)
    }

    func testLegacyMemoryDecodesWithoutPromptUsageCount() throws {
        let data = Data(#"[{"id":"00000000-0000-0000-0000-000000000001","mistaken":"","canonical":"张三","kind":"person","sourceTitle":"","usageCount":0,"isEnabled":true,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}]"#.utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entry = try XCTUnwrap(decoder.decode([RecognitionMemoryEntry].self, from: data).first)
        XCTAssertNil(entry.promptUsageCount)
    }

    func testTranscriptEditSuggestsSingleShortCorrection() {
        let old = Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "今天使用扣得死处理")])
        let new = Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "今天使用Codex处理")])
        let result = RecognitionMemoryStore.correctionSuggestions(
            original: old, edited: new, workspaceID: nil, sourceTitle: "测试")
        XCTAssertEqual(result.first?.mistaken, "扣得死")
        XCTAssertEqual(result.first?.canonical, "Codex")
    }

    func testTranscriptEditReusesKnownPersonKindAndScope() throws {
        let url = temporaryURL()
        let customer = UUID()
        try RecognitionMemoryStore.save([
            RecognitionMemoryEntry(canonical: "客户专家甲", kind: .person, workspaceID: customer)
        ], to: url)
        let old = Transcript(segments: [
            TranscriptSegment(id: 0, start: 0, end: 1, text: "谢谢威艳")
        ])
        let new = Transcript(segments: [
            TranscriptSegment(id: 0, start: 0, end: 1, text: "谢谢客户专家甲")
        ])

        let result = RecognitionMemoryStore.correctionSuggestions(
            original: old, edited: new, workspaceID: UUID(), sourceTitle: "测试", from: url)

        XCTAssertEqual(result.first?.kind, .person)
        XCTAssertEqual(result.first?.workspaceID, customer)
        XCTAssertEqual(result.first?.mistaken, "威艳")
    }

    func testCandidateExtractorKeepsVocabularyButDropsFactsAndTimePhrases() {
        let values = [StructuredMinutes.EvidenceItem(
            content: "“杨卫震”“威艳”“VN”“1分钟内2次”“年底的版本”“年底初的版本”需核对",
            evidence: [])]
        XCTAssertEqual(RecognitionCandidateExtractor.candidates(from: values),
                       ["杨卫震", "威艳", "VN"])
    }

    func testCandidateExtractorUsesModelUncertaintyClassification() {
        let recognition = StructuredMinutes.EvidenceItem(
            content: "“年底版”可能识别有误", evidence: [],
            uncertaintyKind: .speechRecognition)
        let meaning = StructuredMinutes.EvidenceItem(
            content: "“VN”在这里含义不明", evidence: [],
            uncertaintyKind: .unclearMeaning)
        XCTAssertEqual(RecognitionCandidateExtractor.candidates(from: [recognition, meaning]),
                       ["年底版"])
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("recognition-memory-\(UUID().uuidString).json")
    }
}
