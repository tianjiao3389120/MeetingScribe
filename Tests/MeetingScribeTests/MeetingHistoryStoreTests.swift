import XCTest
@testable import MeetingScribe

final class MeetingHistoryStoreTests: XCTestCase {
    func testSaveLoadExportAndDeleteWithoutSourceMedia() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-history-\(UUID().uuidString)")
        let export = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-export-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: export)
        }
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)

        let record = MeetingRecord(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "项目周会", sourcePath: "/missing/meeting.mp4", duration: 120,
            backend: "测试", model: "mock", summaryMarkdown: "# 纪要",
            structuredSummary: nil,
            transcript: Transcript(segments: [
                TranscriptSegment(id: 0, start: 0, end: 2, text: "测试发言"),
            ]), speakerNames: [0: "张三"], usedSummaryFallback: false)

        try MeetingHistoryStore.save(record, root: root)
        let loaded = try MeetingHistoryStore.loadAll(root: root)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, record.id)
        XCTAssertEqual(loaded[0].speakerNames[0], "张三")

        let workspaceID = UUID()
        let updated = try MeetingHistoryStore.updateClassification(
            id: record.id, workspaceID: workspaceID, tags: ["双周会", "客户"], root: root)
        XCTAssertEqual(updated.workspaceID, workspaceID)
        XCTAssertEqual(updated.tags ?? [], ["双周会", "客户"])
        XCTAssertEqual(try MeetingHistoryStore.loadAll(root: root)[0].workspaceID, workspaceID)

        try MeetingHistoryStore.export(updated, to: export)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: export.appendingPathComponent("项目周会 纪要.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: export.appendingPathComponent("项目周会 逐字稿.txt").path))

        try MeetingHistoryStore.remove(id: record.id, root: root)
        XCTAssertTrue(try MeetingHistoryStore.loadAll(root: root).isEmpty)
    }

    func testRegenerationKeepsIndependentVersions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        for summary in ["版本一", "版本二"] {
            try MeetingHistoryStore.save(MeetingRecord(
                title: "同一会议", sourcePath: "/meeting.mp4", duration: 60,
                backend: "测试", model: "mock", summaryMarkdown: summary,
                structuredSummary: nil, transcript: Transcript(segments: []),
                speakerNames: [:], usedSummaryFallback: true), root: root)
        }
        XCTAssertEqual(try MeetingHistoryStore.loadAll(root: root).count, 2)
    }

    func testMaterialsAreCopiedIntoManagedHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-history-\(UUID().uuidString)")
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("客户材料-\(UUID().uuidString).md")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        try "Falcon Gateway 项目计划".write(to: source, atomically: true, encoding: .utf8)
        let material = SupportingMaterial(sourceURL: source, kind: .text,
                                          extractedText: "Falcon Gateway 项目计划")
        let record = MeetingRecord(
            title: "材料会议", sourcePath: "/meeting.mov", duration: 30,
            backend: "测试", model: "mock", summaryMarkdown: "纪要",
            structuredSummary: nil, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false)

        try MeetingHistoryStore.save(record, root: root, materialSources: [material])
        try FileManager.default.removeItem(at: source)
        let reference = try XCTUnwrap(MeetingHistoryStore.loadAll(root: root)[0].materials?.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reference.sourcePath))
        XCTAssertTrue(reference.sourcePath.hasPrefix(root.path))
        XCTAssertEqual(try MaterialExtractor.extract(from: URL(fileURLWithPath: reference.sourcePath))
            .extractedText, "Falcon Gateway 项目计划")
    }

    func testDeletingWorkspaceUngroupsExistingRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceID = UUID()
        let record = MeetingRecord(
            title: "客户周会", sourcePath: "/meeting.mov", duration: 30,
            backend: "测试", model: "mock", summaryMarkdown: "纪要",
            structuredSummary: nil, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false, workspaceID: workspaceID)
        try MeetingHistoryStore.save(record, root: root)

        try MeetingHistoryStore.clearWorkspaceReferences([workspaceID], root: root)
        XCTAssertNil(try MeetingHistoryStore.loadAll(root: root)[0].workspaceID)
    }
}
