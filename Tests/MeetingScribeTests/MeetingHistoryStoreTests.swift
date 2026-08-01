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
            id: record.id, title: "客户项目周会",
            workspaceID: workspaceID, tags: ["双周会", "客户"], root: root)
        XCTAssertEqual(updated.title, "客户项目周会")
        XCTAssertEqual(updated.workspaceID, workspaceID)
        XCTAssertEqual(updated.tags ?? [], ["双周会", "客户"])
        XCTAssertEqual(try MeetingHistoryStore.loadAll(root: root)[0].workspaceID, workspaceID)

        try MeetingHistoryStore.export(updated, to: export)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: export.appendingPathComponent("客户项目周会 纪要.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: export.appendingPathComponent("客户项目周会 逐字稿.txt").path))

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

    func testPendingJobRoundTripAndConditionalClear() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-job-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let job = PendingMeetingJob(sourcePath: "/meeting.mov", workspaceID: UUID(),
                                    tags: ["双周会"], materialPaths: ["/agenda.pdf"])
        try PendingJobStore.save(job, to: url)
        XCTAssertEqual(PendingJobStore.load(from: url)?.tags, ["双周会"])

        PendingJobStore.clear(id: UUID(), at: url)
        XCTAssertNotNil(PendingJobStore.load(from: url))
        PendingJobStore.clear(id: job.id, at: url)
        XCTAssertNil(PendingJobStore.load(from: url))
    }

    func testStorageOverviewReportsHistoryAndMissingSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = MeetingRecord(
            title: "存储测试", sourcePath: "/missing.mov", duration: 10,
            backend: "测试", model: "mock", summaryMarkdown: "纪要内容",
            structuredSummary: nil, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false)
        try MeetingHistoryStore.save(record, root: root)

        let overview = StorageOverview.load(historyRoot: root)
        XCTAssertEqual(overview.meetingCount, 1)
        XCTAssertEqual(overview.missingSourceCount, 1)
        XCTAssertGreaterThan(overview.historyBytes, 0)
    }

    func testMeetingSearchRequiresEveryTermAcrossDifferentFields() {
        let record = MeetingRecord(
            title: "日志治理双周会", sourcePath: "/meeting.mov", duration: 10,
            backend: "测试", model: "mock", summaryMarkdown: "讨论告警优化",
            structuredSummary: nil, transcript: Transcript(segments: []),
            speakerNames: [0: "张三"], usedSummaryFallback: false,
            tags: ["客户", "UAT"])
        XCTAssertTrue(MeetingSearch.matches(
            record, workspaceName: "香港银行", query: "香港银行 UAT 张三"))
        XCTAssertFalse(MeetingSearch.matches(
            record, workspaceName: "香港银行", query: "香港银行 UAT 李四"))
    }

    func testEmailDraftsPersistWithMeetingHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-email-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = MeetingRecord(
            title: "客户周会", sourcePath: "/meeting.mov", duration: 10,
            backend: "测试", model: "mock", summaryMarkdown: "确认下周上线",
            structuredSummary: nil, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false)
        try MeetingHistoryStore.save(record, root: root)
        let drafts = MeetingEmailDrafts(
            chinese: "主题：周会同步", hongKongTraditional: "主旨：週會同步",
            tone: "自然", audience: "客户")

        let updated = try MeetingHistoryStore.updateEmailDrafts(
            id: record.id, drafts: drafts, root: root)
        XCTAssertEqual(updated.emailDrafts?.chinese, drafts.chinese)
        XCTAssertEqual(try MeetingHistoryStore.loadAll(root: root).first?.emailDrafts?.hongKongTraditional,
                       drafts.hongKongTraditional)
    }

    func testLibraryScopesAndFavoriteArchivePersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceID = UUID()
        let minutes = StructuredMinutes(
            title: "周会", nature: "", duration: "", agenda: ["进展"],
            participantAssessment: [], issues: [], requirements: [],
            actionItems: [.init(owner: "张三", task: "更新方案", status: "进行中", due: "下周", evidence: [])],
            agreements: [], afterMeeting: [], uncertainties: [])
        let record = MeetingRecord(
            title: "项目周会", sourcePath: "/meeting.mov", duration: 10,
            backend: "测试", model: "mock", summaryMarkdown: "纪要",
            structuredSummary: minutes, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false, workspaceID: workspaceID)
        try MeetingHistoryStore.save(record, root: root)

        var updated = try MeetingHistoryStore.updateLibraryState(
            id: record.id, favorite: true, root: root)
        XCTAssertEqual(MeetingLibrary.filter([updated], scope: .favorites).count, 1)
        XCTAssertEqual(MeetingLibrary.filter([updated], scope: .pendingActions).count, 1)
        XCTAssertEqual(MeetingLibrary.filter([updated], scope: .workspace(workspaceID)).count, 1)

        updated = try MeetingHistoryStore.updateLibraryState(
            id: record.id, archived: true, root: root)
        XCTAssertTrue(MeetingLibrary.filter([updated], scope: .all).isEmpty)
        XCTAssertEqual(MeetingLibrary.filter([updated], scope: .archived).count, 1)
        XCTAssertEqual(try MeetingHistoryStore.loadAll(root: root).first?.isFavorite, true)
    }
}
