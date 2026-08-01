import XCTest
@testable import MeetingScribe

final class WorkspaceMaterialTests: XCTestCase {
    func testWorkspaceRoundTripPreservesContext() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-workspaces-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = MeetingWorkspace(name: "某客户", kind: .customer,
                                         context: "我方是安全产品厂商")

        try MeetingWorkspaceStore.save([workspace], to: url)
        let loaded = try MeetingWorkspaceStore.load(from: url)
        XCTAssertEqual(loaded.first?.id, workspace.id)
        XCTAssertEqual(loaded.first?.context, "我方是安全产品厂商")
    }

    func testTextMaterialExtractionAndLengthLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("material-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try String(repeating: "材料", count: 10_000).write(
            to: url, atomically: true, encoding: .utf8)

        let material = try MaterialExtractor.extract(from: url)
        XCTAssertEqual(material.kind, .text)
        XCTAssertEqual(material.extractedText.count, MaterialExtractor.perFileCharacterLimit)
    }

    func testUnsupportedMaterialIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("material.docx")
        XCTAssertThrowsError(try MaterialExtractor.extract(from: url))
    }

    @MainActor
    func testHongKongScenarioUsesAutomaticLanguageAndMaterialTerms() {
        let material = SupportingMaterial(
            sourceURL: URL(fileURLWithPath: "/tmp/Project Atlas.md"),
            kind: .text,
            extractedText: "Client 要确认 Falcon Gateway 的 deployment timeline。")
        let prompt = PipelineRunner.transcriptionPrompt(
            scenario: .hongKongMixed,
            glossary: "通用词表",
            materials: [material])
        let trimmed = Transcriber.trimGlossary(prompt)

        XCTAssertEqual(RecognitionScenario.hongKongMixed.whisperLanguage, "auto")
        XCTAssertTrue(trimmed.contains("香港粤语"))
        XCTAssertTrue(trimmed.contains("Falcon Gateway"))
        XCTAssertTrue(RecognitionScenario.hongKongMixed.analysisGuidance.contains("简体书面中文"))
    }
}
