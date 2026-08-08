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

        let realtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-realtime-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: realtimeRoot) }
        try FileManager.default.createDirectory(at: realtimeRoot, withIntermediateDirectories: true)
        try "字幕".write(to: realtimeRoot.appendingPathComponent("realtime-test.txt"),
                       atomically: true, encoding: .utf8)
        let overview = StorageOverview.load(historyRoot: root, realtimeRoot: realtimeRoot)
        XCTAssertEqual(overview.meetingCount, 1)
        XCTAssertEqual(overview.missingSourceCount, 1)
        XCTAssertGreaterThan(overview.historyBytes, 0)
        XCTAssertEqual(overview.realtimeCount, 1)
        XCTAssertGreaterThan(overview.realtimeBytes, 0)
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

    func testEditingActionPersistsAndRegeneratesMarkdown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-action-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let minutes = StructuredMinutes(
            title: "项目周会", nature: "周会", duration: "30 分钟", agenda: ["进展"],
            participantAssessment: [], issues: [], requirements: [],
            actionItems: [.init(owner: "张三", task: "提交方案", status: "进行中",
                                due: "周五", evidence: ["[12:00]"])],
            agreements: [], afterMeeting: [], uncertainties: [])
        let record = MeetingRecord(
            title: "项目周会", sourcePath: "/meeting.mov", duration: 10,
            backend: "测试", model: "mock",
            summaryMarkdown: StructuredMinutesRenderer.markdown(from: minutes),
            structuredSummary: minutes, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false)
        try MeetingHistoryStore.save(record, root: root)

        var action = minutes.actionItems[0]
        action.owner = " 李四 "
        action.task = " 完成上线检查 "
        action.status = "已完成"
        action.due = "下周一"
        let updated = try MeetingHistoryStore.updateActionItem(
            id: record.id, index: 0, action: action, root: root)

        XCTAssertEqual(updated.openActionCount, 0)
        XCTAssertEqual(updated.structuredSummary?.actionItems[0].owner, "李四")
        XCTAssertTrue(updated.summaryMarkdown.contains("- [x] 完成上线检查（下周一） [已完成]"))
        XCTAssertTrue(updated.summaryMarkdown.contains("（证据：[12:00]）"))
        let loaded = try XCTUnwrap(MeetingHistoryStore.loadAll(root: root).first)
        XCTAssertEqual(loaded.structuredSummary?.actionItems[0].status, "已完成")
        let minutesFile = root.appendingPathComponent(record.id.uuidString)
            .appendingPathComponent("minutes.md")
        XCTAssertEqual(try String(contentsOf: minutesFile, encoding: .utf8), updated.summaryMarkdown)
    }

    func testApplyingEvidenceBackedSuggestionUpdatesHistoricalAction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-action-suggestion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceID = UUID()
        let oldMinutes = StructuredMinutes(
            title: "上期", nature: "", duration: "", agenda: ["进展"],
            participantAssessment: [], issues: [], requirements: [],
            actionItems: [.init(owner: "张三", task: "提交上线方案", status: "进行中",
                                due: "周五", evidence: [])],
            agreements: [], afterMeeting: [], uncertainties: [])
        var old = MeetingRecord(
            createdAt: Date(timeIntervalSince1970: 100), title: "上期会议",
            sourcePath: "/old.mov", duration: 10, backend: "测试", model: "mock",
            summaryMarkdown: StructuredMinutesRenderer.markdown(from: oldMinutes),
            structuredSummary: oldMinutes, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false, workspaceID: workspaceID)
        try MeetingHistoryStore.save(old, root: root)
        let targetID = ActionTracking.id(for: oldMinutes.actionItems[0], meetingID: old.id, index: 0)
        var current = MeetingRecord(
            createdAt: Date(timeIntervalSince1970: 200), title: "本期会议",
            sourcePath: "/new.mov", duration: 10, backend: "测试", model: "mock",
            summaryMarkdown: "纪要", structuredSummary: oldMinutes,
            transcript: Transcript(segments: []), speakerNames: [:],
            usedSummaryFallback: false, workspaceID: workspaceID)
        let suggestion = ActionStatusSuggestion(
            targetMeetingID: old.id, targetActionID: targetID, task: "提交上线方案",
            previousStatus: "进行中", proposedStatus: "已完成", evidence: ["[08:20]"])
        current.actionStatusSuggestions = [suggestion]
        try MeetingHistoryStore.save(current, root: root)

        let updated = try MeetingHistoryStore.applyActionSuggestion(
            sourceMeetingID: current.id, suggestionID: suggestion.id, root: root)
        XCTAssertEqual(updated.count, 2)
        let records = try MeetingHistoryStore.loadAll(root: root)
        old = try XCTUnwrap(records.first { $0.id == old.id })
        current = try XCTUnwrap(records.first { $0.id == current.id })
        XCTAssertEqual(old.structuredSummary?.actionItems[0].status, "已完成")
        XCTAssertTrue(old.summaryMarkdown.contains("- [x] 提交上线方案"))
        XCTAssertEqual(current.appliedActionSuggestionIDs, [suggestion.id])
    }

    func testHistoricalReviewSuggestionsPersistWithoutChangingActionStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let minutes = StructuredMinutes(
            title: "后续会议", nature: "周会", duration: "10 分钟", agenda: [],
            participantAssessment: [], issues: [], requirements: [],
            actionItems: [.init(owner: "张三", task: "整理材料", status: "进行中",
                                due: "本周", evidence: ["[01:00]"])],
            agreements: [], afterMeeting: [], uncertainties: [])
        let meeting = MeetingRecord(
            title: "后续会议", sourcePath: "/meeting.mov", duration: 600,
            backend: "测试", model: "mock", summaryMarkdown: "纪要",
            structuredSummary: minutes, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false)
        try MeetingHistoryStore.save(meeting, root: root)
        let suggestion = ActionStatusSuggestion(
            targetMeetingID: UUID(), targetActionID: "MS-OLD-1", task: "提交方案",
            previousStatus: "进行中", proposedStatus: "已完成", evidence: ["[12:34]"])

        let updated = try MeetingHistoryStore.updateActionSuggestions(
            id: meeting.id, suggestions: [suggestion], root: root)

        XCTAssertEqual(updated.actionStatusSuggestions, [suggestion])
        XCTAssertEqual(updated.structuredSummary?.actionItems.first?.status,
                       meeting.structuredSummary?.actionItems.first?.status)
        XCTAssertEqual(try MeetingHistoryStore.loadAll(root: root).first?
            .actionStatusSuggestions, [suggestion])
    }

    func testLibrarySortingAndTimeSections() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 8, hour: 12)))

        func record(_ title: String, daysAgo: Int, hour: Int = 9) throws -> MeetingRecord {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -daysAgo, to: now))
            let date = try XCTUnwrap(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day))
            return MeetingRecord(
                createdAt: date, title: title, sourcePath: "/\(title).mov", duration: 10,
                backend: "测试", model: "mock", summaryMarkdown: "纪要",
                structuredSummary: nil, transcript: Transcript(segments: []),
                speakerNames: [:], usedSummaryFallback: false)
        }

        let records = try [
            record("今天会议", daysAgo: 0),
            record("昨天会议", daysAgo: 1),
            record("较早会议", daysAgo: 20),
        ]

        XCTAssertEqual(MeetingLibrary.sorted(records, by: .newest).map(\.title),
                       ["今天会议", "昨天会议", "较早会议"])
        XCTAssertEqual(MeetingLibrary.sorted(records, by: .oldest).map(\.title),
                       ["较早会议", "昨天会议", "今天会议"])

        let newest = MeetingLibrary.timeSections(
            records, sort: .newest, now: now, calendar: calendar)
        XCTAssertEqual(newest.map(\.title), ["今天", "昨天", "更早"])
        XCTAssertEqual(newest.flatMap(\.records).map(\.title),
                       ["今天会议", "昨天会议", "较早会议"])

        let oldest = MeetingLibrary.timeSections(
            records, sort: .oldest, now: now, calendar: calendar)
        XCTAssertEqual(oldest.map(\.title), ["更早", "昨天", "今天"])

        let alphabetic = MeetingLibrary.timeSections(
            records, sort: .title, now: now, calendar: calendar)
        XCTAssertEqual(alphabetic.map(\.title), ["按名称"])
        XCTAssertEqual(alphabetic[0].records.map(\.title), ["较早会议", "今天会议", "昨天会议"])
    }

    func testLibraryTagScopeMatchesCaseInsensitivelyAndExcludesArchived() {
        var active = MeetingRecord(
            title: "客户周会", sourcePath: "/active.mov", duration: 10,
            backend: "测试", model: "mock", summaryMarkdown: "纪要",
            structuredSummary: nil, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false, tags: ["HIDS", "双周会"])
        var archived = active
        archived.title = "已归档会议"
        archived.isArchived = true

        XCTAssertEqual(MeetingLibrary.filter(
            [active, archived], scope: .meetingTag("hids")).map(\.title), ["客户周会"])
        active.tags = []
        XCTAssertTrue(MeetingLibrary.filter([active], scope: .meetingTag("HIDS")).isEmpty)
    }

    func testMeetingTagSuggestionsAndToggleDeduplicateCaseInsensitively() {
        let first = MeetingRecord(
            title: "会议一", sourcePath: "/one.mov", duration: 10,
            backend: "测试", model: "mock", summaryMarkdown: "纪要",
            structuredSummary: nil, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false, tags: ["HIDS", "双周会"])
        var second = first
        second.title = "会议二"
        second.tags = ["hids", "客户"]

        let suggestions = MeetingTags.suggestions(from: [first, second])
        XCTAssertEqual(suggestions.first, "HIDS")
        XCTAssertEqual(Set(suggestions.dropFirst()), Set(["客户", "双周会"]))
        XCTAssertEqual(MeetingTags.toggling("双周会", in: "HIDS"), "HIDS, 双周会")
        XCTAssertEqual(MeetingTags.toggling("hids", in: "HIDS, 双周会"), "双周会")
        XCTAssertEqual(MeetingTags.parse("HIDS， hids, 双周会"), ["HIDS", "双周会"])
    }
}
