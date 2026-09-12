import XCTest
import CoreGraphics
@testable import MeetingScribe

final class WorkspaceMaterialTests: XCTestCase {
    func testLegacyFixedMeetingMigratesUnderFallbackCustomerWithMeetingType() {
        let legacy = MeetingWorkspace(name: "管理周会", kind: .recurring)

        let migrated = MeetingWorkspaceStore.normalizeHierarchy([legacy])
        let customer = migrated.first(where: \.isCustomer)
        let project = migrated.first { $0.id == legacy.id }

        XCTAssertEqual(customer?.name, "未归属客户")
        XCTAssertEqual(project?.kind, .project)
        XCTAssertEqual(project?.customerID, customer?.id)
        XCTAssertEqual(project?.configuredMeetingTypes, ["固定会议"])
    }
    func testAdaptiveFramePlannerParsesBoundsDeduplicatesAndCapsRequests() {
        let raw = #"prefix {"requests":[{"seconds":12.1,"reason":"数字","radius":3},{"seconds":12.4,"reason":"重复","radius":3},{"seconds":-1,"reason":"越界","radius":3},{"seconds":20,"reason":"A","radius":3},{"seconds":30,"reason":"B","radius":3},{"seconds":40,"reason":"C","radius":3},{"seconds":50,"reason":"D","radius":3},{"seconds":60,"reason":"E","radius":3},{"seconds":70,"reason":"F","radius":3}]} suffix"#
        let requests = AdaptiveFramePlanner.parse(raw, duration: 100)

        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests.first?.seconds, 12.1)
        XCTAssertFalse(requests.contains { $0.seconds < 0 })
    }

    func testAdaptiveFramePlannerOnlySelectsLocallyRelevantSegmentsAcrossTimeline() {
        let transcript = Transcript(segments: [
            TranscriptSegment(id: 0, start: 1, end: 2, text: "大家好，今天开始开会。"),
            TranscriptSegment(id: 1, start: 100, end: 101, text: "大家看一下这里的架构图。"),
            TranscriptSegment(id: 2, start: 900, end: 901, text: "最终数据是 12345 条，截止日期为 8 月 30 日。")
        ])
        let timeline = AdaptiveFramePlanner.candidateTimeline(from: transcript)

        XCTAssertFalse(timeline.contains("今天开始开会"))
        XCTAssertTrue(timeline.contains("架构图"))
        XCTAssertTrue(timeline.contains("12345"))
        XCTAssertTrue(timeline.contains("15:00"))
    }

    func testAdaptiveFramePlannerFallbackKeepsExplicitScreenDemonstrations() {
        let transcript = Transcript(segments: [
            TranscriptSegment(id: 0, start: 10, end: 12, text: "大家看一下这里的告警列表。"),
            TranscriptSegment(id: 1, start: 12, end: 14, text: "这个也是同一页。"),
            TranscriptSegment(id: 2, start: 60, end: 62, text: "版本号是 091，结果有 24 项。")
        ])

        let requests = AdaptiveFramePlanner.fallbackRequests(from: transcript, duration: 90)

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.seconds, 10)
        XCTAssertEqual(requests.last?.seconds, 60)
    }

    func testPromptTimelineExplainsWhyAdaptiveFrameWasCaptured() {
        let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data([0, 0, 0, 255]) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let capture = ScreenCapture(id: 7, time: 12, duration: 30, image: image,
                                    recognizedText: ["版本 5.1.7"],
                                    evidenceReason: "核对版本号", fingerprint: 0)
        let assets = MeetingAssets(sourceURL: URL(fileURLWithPath: "/tmp/test.mov"),
                                   duration: 20, transcript: Transcript(segments: []),
                                   captures: [capture], hasVideo: true)
        let timeline = PromptBuilder(assets: assets, contextHint: "", imageCaptureIDs: [])
            .buildTimeline()

        XCTAssertTrue(timeline.contains("补充核对原因：核对版本号"))
        XCTAssertTrue(timeline.contains("版本 5.1.7"))
    }

    func testAdaptiveScreenStatsCountUniqueCitations() {
        let minutes = StructuredMinutes(
            title: "测试会议", nature: "", duration: "", agenda: ["核对"],
            participantAssessment: [],
            issues: [.init(title: "版本", status: "待确认", rootCause: "", solution: "",
                           progress: "", evidence: ["屏幕 08:20", "[08:22]"])],
            requirements: [],
            actionItems: [.init(owner: "张三", task: "核对", status: "待办", due: "",
                               evidence: ["屏幕 08:20", "屏幕 09:10"])],
            agreements: [], afterMeeting: [], uncertainties: [])

        XCTAssertEqual(Analyzer.screenCitationCount(in: minutes), 2)
    }

    func testAdaptiveOCRSelectionFoldsProbeTripletsAndCapsPayload() {
        let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data([0, 0, 0, 255]) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let captures = [0.0, 3.0, 6.0, 30.0, 33.0, 36.0, 60.0].enumerated().map {
            ScreenCapture(id: $0.offset, time: $0.element, duration: 1, image: image,
                          recognizedText: [String(repeating: "字", count: $0.offset + 1)],
                          evidenceReason: "核对", fingerprint: UInt64($0.offset))
        }

        let selected = Analyzer.selectAdaptiveOCRCaptures(from: captures, limit: 6)

        XCTAssertEqual(selected.count, 3)
        XCTAssertTrue(selected.contains(2))
        XCTAssertTrue(selected.contains(5))
        XCTAssertTrue(selected.contains(6))
    }

    func testVisualEvidenceSelectionKeepsOneFramePerEventWithoutRequiringOCR() {
        let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data([0, 0, 0, 255]) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let times = [0.0, 4.0, 8.0, 30.0, 34.0, 60.0]
        let captures = times.enumerated().map {
            let reason = $0.offset < 3 ? "事件A" : ($0.offset < 5 ? "事件B" : "事件C")
            return ScreenCapture(id: $0.offset, time: $0.element, duration: 1, image: image,
                                 recognizedText: [], evidenceReason: reason,
                                 fingerprint: UInt64($0.offset))
        }

        let selected = Analyzer.selectVisualEvidenceCaptures(from: captures, limit: 6)

        XCTAssertEqual(selected.count, 3)
        XCTAssertTrue(selected.contains(1))
        XCTAssertTrue(selected.contains(3) || selected.contains(4))
        XCTAssertTrue(selected.contains(5))
    }

    @MainActor
    func testTargetedEvidenceDeduplicatesOnlyWithinTargetedProbeSet() {
        let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data([0, 0, 0, 255]) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let captures = [
            ScreenCapture(id: 1, time: 10, duration: 1, image: image,
                          evidenceReason: "事件A", fingerprint: 0),
            ScreenCapture(id: 2, time: 12, duration: 1, image: image,
                          evidenceReason: "事件A", fingerprint: 0),
            ScreenCapture(id: 3, time: 30, duration: 1, image: image,
                          evidenceReason: "事件B", fingerprint: UInt64.max)
        ]

        let result = PipelineRunner.distinctEvidenceFrames(captures)

        XCTAssertEqual(result.map(\.id), [1, 3])
    }

    func testModelTrackingIDsAreRecoveredButNeverRemainInTaskText() {
        var value = StructuredMinutes(
            title: "项目例会", nature: "", duration: "", agenda: ["进展"],
            participantAssessment: [], issues: [], requirements: [],
            actionItems: [
                .init(owner: "张三", task: "[MS-ABC-123] 提交上线方案", status: "进行中", due: "", evidence: []),
                .init(owner: "李四", task: "[MS-ONE] [MS-TWO]", status: "", due: "", evidence: [])
            ], agreements: [], afterMeeting: [], uncertainties: [])
        ActionTracking.normalizeModelOutput(&value)
        XCTAssertEqual(value.actionItems.count, 1)
        XCTAssertEqual(value.actionItems[0].trackingID, "MS-ABC-123")
        XCTAssertEqual(value.actionItems[0].task, "提交上线方案")
    }

    func testPreparingMeetingKeepsActionsAsInfoAndClearsPendingLegacyProposals() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let workspaceID = UUID()
        let legacy = ProjectActionProposal(
            workspaceID: workspaceID, meetingID: UUID(), meetingTitle: "旧会议",
            meetingDate: Date(), kind: .create, task: "旧待办", owner: "张三",
            status: "进行中", due: "", previousStatus: nil, evidence: ["[01:00]"])
        try ProjectLedgerStore.save(ProjectLedger(proposals: [legacy]), to: url)
        let minutes = StructuredMinutes(
            title: "项目周会", nature: "", duration: "", agenda: ["进展"],
            participantAssessment: [], issues: [], requirements: [],
            actionItems: [.init(owner: "李四", task: "发送纪要", status: "待办",
                                due: "今天", evidence: ["[11:00]"])],
            agreements: [], afterMeeting: [], uncertainties: [])
        let record = MeetingRecord(
            title: "项目周会", sourcePath: "/meeting.srt", duration: 60,
            backend: "测试", model: "mock", summaryMarkdown: "纪要",
            structuredSummary: minutes, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false, workspaceID: workspaceID)

        let ledger = try ProjectLedgerStore.prepareProposals(for: record, at: url)
        XCTAssertTrue(ledger.pendingProposals(for: workspaceID).isEmpty)
        XCTAssertTrue(ledger.actions(for: workspaceID).isEmpty)
    }

    func testProjectIssueLedgerRequiresConfirmationAndKeepsTimeline() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-issues-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let workspaceID = UUID()
        func record(date: TimeInterval, status: String, progress: String) -> MeetingRecord {
            let minutes = StructuredMinutes(
                title: "周会", nature: "", duration: "", agenda: ["进展"],
                participantAssessment: [],
                issues: [.init(trackingID: "MS-ISSUE-1",
                               rollingSummary: "滚动档案：\(progress)", title: "供应商引擎异常",
                               status: status, background: "安装组件后异常关闭",
                               rootCause: "等待供应商确认", solution: "分析日志",
                               progress: progress, evidence: ["[10:00]"])],
                requirements: [], actionItems: [], agreements: [], afterMeeting: [],
                uncertainties: [])
            return MeetingRecord(createdAt: Date(timeIntervalSince1970: date), title: "周会",
                                 sourcePath: "/meeting.srt", duration: 60,
                                 backend: "测试", model: "mock", summaryMarkdown: "纪要",
                                 structuredSummary: minutes, transcript: Transcript(segments: []),
                                 speakerNames: [:], usedSummaryFallback: false,
                                 workspaceID: workspaceID)
        }

        var ledger = try ProjectLedgerStore.prepareProposals(
            for: record(date: 100, status: "进行中", progress: "等待日志"), at: url)
        let create = try XCTUnwrap(ledger.pendingIssueProposals(for: workspaceID).first)
        XCTAssertEqual(create.kind, .create)
        ledger = try ProjectLedgerStore.acceptIssue(proposalID: create.id, at: url)
        XCTAssertEqual(ledger.issues.first?.background, "安装组件后异常关闭")
        XCTAssertEqual(ledger.analysis(for: "MS-ISSUE-1")?.summary, "滚动档案：等待日志")
        XCTAssertEqual(ledger.analysis(for: "MS-ISSUE-1")?.timeline?.count, 1)

        ledger = try ProjectLedgerStore.prepareProposals(
            for: record(date: 200, status: "等待中", progress: "完成三轮分析"), at: url)
        let update = try XCTUnwrap(ledger.pendingIssueProposals(for: workspaceID).first)
        XCTAssertEqual(update.kind, .update)
        ledger = try ProjectLedgerStore.acceptIssue(proposalID: update.id, at: url)
        XCTAssertEqual(ledger.issues.first?.events.count, 2)
        XCTAssertEqual(ledger.issues.first?.events.last?.progress, "完成三轮分析")
        XCTAssertEqual(ledger.analysis(for: "MS-ISSUE-1")?.summary, "滚动档案：完成三轮分析")
        XCTAssertEqual(ledger.analysis(for: "MS-ISSUE-1")?.timeline?.count, 2)
    }

    func testProjectIssueUpdateKeepsExistingStatusWhenProposalStatusIsBlank() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-issue-blank-status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let workspaceID = UUID()
        let issue = ProjectIssue(
            id: "MS-ISSUE-1", workspaceID: workspaceID, title: "引擎异常", aliases: [],
            background: "", rootCause: "待查", solution: "分析日志", status: "进行中",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100), sourceMeetingID: UUID(), events: [])
        let proposal = ProjectIssueProposal(
            workspaceID: workspaceID, meetingID: UUID(), meetingTitle: "周会",
            meetingDate: Date(timeIntervalSince1970: 200), kind: .update,
            targetIssueID: issue.id, title: issue.title, background: "", rootCause: "待查",
            solution: "分析日志", progress: "新增日志", status: "", previousStatus: issue.status,
            evidence: ["[10:00]"])
        try ProjectLedgerStore.save(
            ProjectLedger(issues: [issue], issueProposals: [proposal]), to: url)

        let ledger = try ProjectLedgerStore.acceptIssue(proposalID: proposal.id, at: url)
        XCTAssertEqual(ledger.issues[0].status, "进行中")
        XCTAssertEqual(ledger.issues[0].events.last?.currentStatus, "进行中")
    }

    func testProjectIssueCreationRejectsDuplicateStableID() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-issue-duplicate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let workspaceID = UUID()
        let issue = ProjectIssue(
            id: "MS-ISSUE-1", workspaceID: workspaceID, title: "既有问题", aliases: [],
            background: "", rootCause: "", solution: "", status: "进行中",
            createdAt: Date(), updatedAt: Date(), sourceMeetingID: UUID(), events: [])
        let proposal = ProjectIssueProposal(
            workspaceID: workspaceID, meetingID: UUID(), meetingTitle: "周会",
            meetingDate: Date(), kind: .create, targetIssueID: issue.id, title: "重复问题",
            background: "", rootCause: "", solution: "", progress: "", status: "进行中",
            previousStatus: nil, evidence: ["[01:00]"])
        try ProjectLedgerStore.save(
            ProjectLedger(issues: [issue], issueProposals: [proposal]), to: url)

        XCTAssertThrowsError(try ProjectLedgerStore.acceptIssue(proposalID: proposal.id, at: url))
        XCTAssertEqual(try ProjectLedgerStore.load(from: url).issues.count, 1)
    }

    func testIssueProposalCanBeManuallyAssociatedWithExistingIssue() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-issue-link-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let workspaceID = UUID()
        let existing = ProjectIssue(
            id: "MS-ISSUE-EXISTING", workspaceID: workspaceID, title: "供应商引擎异常",
            aliases: [], background: "历史背景", rootCause: "待确认", solution: "分析日志",
            status: "进行中", createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100), sourceMeetingID: UUID(), events: [])
        var ledger = ProjectLedger(issues: [existing])
        let proposal = ProjectIssueProposal(
            workspaceID: workspaceID, meetingID: UUID(), meetingTitle: "本周会议",
            meetingDate: Date(timeIntervalSince1970: 200), kind: .create,
            targetIssueID: "MS-ISSUE-WRONG", title: "引擎主动退出",
            background: "", rootCause: "供应商内部错误", solution: "供应商分析",
            progress: "完成三轮日志分析", status: "等待中", previousStatus: nil,
            evidence: ["[10:00]"])
        ledger.issueProposals = [proposal]
        try ProjectLedgerStore.save(ledger, to: url)

        ledger = try ProjectLedgerStore.acceptIssue(
            proposalID: proposal.id, targetIssueID: existing.id, at: url)

        XCTAssertEqual(ledger.issues.count, 1)
        XCTAssertEqual(ledger.issues[0].events.last?.progress, "完成三轮日志分析")
        XCTAssertEqual(ledger.issues[0].status, "等待中")
        XCTAssertEqual(ledger.issueProposals[0].resolution, .accepted)
    }

    func testAcceptedIssueAssociationCanBeReopenedWithoutLeavingTimelineEvent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reopen-issue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let workspaceID = UUID()
        let proposal = ProjectIssueProposal(
            workspaceID: workspaceID, meetingID: UUID(), meetingTitle: "首次会议",
            meetingDate: Date(timeIntervalSince1970: 100), kind: .create,
            targetIssueID: nil, title: "引擎异常", background: "背景", rootCause: "待查",
            solution: "分析日志", progress: "首次发现", status: "进行中",
            previousStatus: nil, evidence: ["[01:00]"])
        try ProjectLedgerStore.save(ProjectLedger(issueProposals: [proposal]), to: url)
        var ledger = try ProjectLedgerStore.acceptIssue(proposalID: proposal.id, at: url)
        XCTAssertEqual(ledger.issues.count, 1)
        XCTAssertNotNil(ledger.issueProposals[0].targetIssueID)

        ledger = try ProjectLedgerStore.reopenIssue(proposalID: proposal.id, at: url)
        XCTAssertTrue(ledger.issues.isEmpty)
        XCTAssertEqual(ledger.issueProposals[0].resolution, .pending)
    }

    func testWorkspaceResolverRepairsTextOnlyCustomerClassification() {
        let customer = MeetingWorkspace(name: "中银香港", kind: .customer)
        let other = MeetingWorkspace(name: "其他客户", kind: .customer)
        XCTAssertEqual(MeetingWorkspaceStore.resolve(
            id: nil, customerName: " 中银香港 ", projectName: nil,
            from: [other, customer])?.id, customer.id)
    }

    func testWorkspaceResolverRepairsLegacyCustomerIDWhenProjectNameExists() {
        let customer = MeetingWorkspace(name: "中银香港", kind: .customer)
        let project = MeetingWorkspace(name: "主机安全", kind: .project,
                                       customerID: customer.id)

        let resolved = MeetingWorkspaceStore.resolve(
            id: customer.id, customerName: customer.name, projectName: project.name,
            from: [customer, project])

        XCTAssertEqual(resolved?.id, project.id)
        XCTAssertTrue(resolved?.isProject == true)
    }

    func testWorkspaceResolverNeverMatchesProjectOutsideTypedCustomer() {
        let customerA = MeetingWorkspace(name: "客户 A", kind: .customer)
        let customerB = MeetingWorkspace(name: "客户 B", kind: .customer)
        let projectB = MeetingWorkspace(name: "同名项目", kind: .project,
                                        customerID: customerB.id)
        let values = [customerA, customerB, projectB]

        XCTAssertNil(MeetingWorkspaceStore.resolve(
            id: nil, customerName: "不存在的客户", projectName: "同名项目", from: values))
        XCTAssertNil(MeetingWorkspaceStore.resolve(
            id: nil, customerName: "客户 A", projectName: "同名项目", from: values))
        XCTAssertNil(MeetingWorkspaceStore.resolve(
            id: nil, customerName: nil, projectName: "同名项目", from: values))
    }

    func testIssueTrackingOnlyMatchesConfirmedProjectIssues() {
        let confirmed = ProjectIssue(
            id: "MS-ISSUE-CONFIRMED", workspaceID: UUID(), title: "供应商引擎异常",
            aliases: [], background: "组件退出", rootCause: "待查", solution: "分析日志",
            status: "进行中", createdAt: Date(), updatedAt: Date(),
            sourceMeetingID: UUID(), events: [])
        var minutes = StructuredMinutes(
            title: "周会", nature: "", duration: "", agenda: [], participantAssessment: [],
            issues: [.init(title: "供应商引擎异常", status: "进行中", background: "组件退出",
                           rootCause: "待查", solution: "分析日志", progress: "", evidence: [])],
            requirements: [], actionItems: [], agreements: [], afterMeeting: [], uncertainties: [])

        IssueTracking.prepare(&minutes, confirmedIssues: [confirmed])
        XCTAssertEqual(minutes.issues[0].trackingID, confirmed.id)

        minutes.issues[0].trackingID = nil
        IssueTracking.prepare(&minutes, confirmedIssues: [])
        XCTAssertNotEqual(minutes.issues[0].trackingID, confirmed.id)
    }

    func testIssueCandidateSelectionKeepsAllIssuesBelowThreshold() {
        let issues = (0..<IssueTracking.unfilteredIssueLimit).map {
            candidateIssue(index: $0, title: "问题 \($0)")
        }

        let selection = IssueTracking.candidateSelection(from: issues, evidenceText: "问题 3")

        XCTAssertEqual(selection.detailed.count, IssueTracking.unfilteredIssueLimit)
        XCTAssertTrue(selection.index.isEmpty)
        XCTAssertEqual(selection.omittedCount, 0)
        XCTAssertFalse(selection.filtered)
    }

    func testIssueCandidateSelectionUsesEvidenceAndKeepsLightweightIndex() {
        let issues = (0..<30).map {
            candidateIssue(index: $0, title: $0 == 29 ? "Agent CPU占用异常" : "历史问题 \($0)")
        }

        let selection = IssueTracking.candidateSelection(
            from: issues, evidenceText: "今天需要继续排查 Agent CPU占用异常和升级兼容性")

        XCTAssertEqual(selection.detailed.count, IssueTracking.filteredDetailedLimit)
        XCTAssertEqual(selection.index.count, 30 - IssueTracking.filteredDetailedLimit)
        XCTAssertEqual(selection.omittedCount, 0)
        XCTAssertTrue(selection.filtered)
        XCTAssertTrue(selection.detailed.contains { $0.title == "Agent CPU占用异常" })
        XCTAssertEqual(selection.reasons["标题/别名命中"], 1)
    }

    func testIssueCandidateSelectionCapsLightweightIndex() {
        let issues = (0..<70).map { candidateIssue(index: $0, title: "历史问题 \($0)") }

        let selection = IssueTracking.candidateSelection(from: issues, evidenceText: "无明显命中")

        XCTAssertEqual(selection.detailed.count, IssueTracking.filteredDetailedLimit)
        XCTAssertEqual(selection.index.count, IssueTracking.lightweightIndexLimit)
        XCTAssertEqual(selection.omittedCount, 22)
        XCTAssertTrue(selection.filtered)
    }

    func testIssueCandidateSelectionUsesCharacterBudgetEvenWithFewIssues() {
        let longText = String(repeating: "详细背景", count: 120)
        let issues = (0..<10).map {
            ProjectIssue(
                id: "MS-LONG-\($0)", workspaceID: UUID(), title: "长问题 \($0)", aliases: [],
                background: longText, rootCause: longText, solution: longText, status: "进行中",
                createdAt: Date(), updatedAt: Date(), sourceMeetingID: UUID(), events: [])
        }

        let selection = IssueTracking.candidateSelection(from: issues, evidenceText: "长问题")

        XCTAssertTrue(selection.filtered)
        XCTAssertEqual(selection.detailed.count, IssueTracking.filteredDetailedLimit)
        XCTAssertEqual(selection.index.count, 2)
    }

    func testIssueCandidateSelectionToleratesPartialTranscriptMatch() {
        let issues = (0..<30).map {
            candidateIssue(index: $0, title: $0 == 0 ? "WebShell白名单批量导入异常" : "无关问题 \($0)")
        }

        let selection = IssueTracking.candidateSelection(
            from: issues, evidenceText: "今天说到 WebShell 白名单，批量导入还是失败")

        XCTAssertTrue(selection.detailed.contains { $0.title == "WebShell白名单批量导入异常" })
        XCTAssertGreaterThanOrEqual(selection.reasons["BM25匹配"] ?? 0, 1)
    }

    func testClosedIssueCanBeRecalledAsReopenCandidate() {
        var closed = candidateIssue(index: 1, title: "第三方杀毒软件误报Agent引擎文件")
        closed.status = "已闭环"
        let unrelated = (2..<8).map { candidateIssue(index: $0, title: "其他已关闭问题 \($0)") }

        let candidates = IssueTracking.closedReopenCandidates(
            from: [closed] + unrelated,
            evidenceText: "Symantec再次对Agent引擎文件报病毒，需要确认是否复发")

        XCTAssertEqual(candidates.first?.issue.id, closed.id)
        XCTAssertLessThanOrEqual(candidates.count, IssueTracking.closedReopenLimit)
    }

    func testPostMinutesAssociationUsesConciseIssueInsteadOfUnrelatedMeetingText() {
        var relevant = candidateIssue(index: 1, title: "第三方杀毒软件误报Agent引擎文件")
        relevant.status = "已闭环"
        relevant.background = "Symantec扫描Agent目录DLL和病毒名称字符串后产生误报"
        var unrelated = candidateIssue(index: 2, title: "Bash告警无法追溯来源IP")
        unrelated.status = "已闭环"
        let current = StructuredMinutes.Issue(
            title: "Symantec对Agent组件包产生病毒告警", status: "待确认",
            background: "样本包含病毒名称字符串", rootCause: "可能为字符串规则误报",
            solution: "提交Symantec分析", progress: "样本已提交", evidence: ["[41:24]"])

        let selection = IssueTracking.associationCandidates(
            for: [current], from: [unrelated, relevant])

        XCTAssertEqual(selection.candidates.first?.id, relevant.id)
        XCTAssertTrue(selection.rankingLines.first?.contains(relevant.title) == true)
    }

    func testPostMinutesAssociationRetrievesUsingRollingProfile() {
        let relevant = candidateIssue(index: 1, title: "终端组件异常")
        let unrelated = candidateIssue(index: 2, title: "终端组件异常排查")
        let current = StructuredMinutes.Issue(
            title: "灾备切换失败", status: "进行中", background: "生产到灾备无法统一切换",
            rootCause: "待确认", solution: "补充切换能力", progress: "已提出需求", evidence: [])

        let selection = IssueTracking.associationCandidates(
            for: [current], from: [unrelated, relevant],
            profilesByIssueID: [relevant.id: "生产环境到灾备环境统一切换能力缺失"])

        XCTAssertEqual(selection.candidates.first?.id, relevant.id)
    }

    func testPostMinutesAssociationPenalizesNegativeTermConflict() {
        var conflicted = candidateIssue(index: 1, title: "Agent 管控异常")
        conflicted.searchTerms = ["终端管控"]
        conflicted.negativeTerms = ["USB管控"]
        var relevant = candidateIssue(index: 2, title: "Agent 管控异常")
        relevant.searchTerms = ["USB管控", "外设策略"]
        let current = StructuredMinutes.Issue(
            title: "USB管控策略异常", status: "进行中", rootCause: "",
            solution: "", progress: "外设策略未生效", evidence: [])

        let selection = IssueTracking.associationCandidates(
            for: [current], from: [conflicted, relevant])

        XCTAssertEqual(selection.candidates.first?.id, relevant.id)
    }

    func testIssueAssociationResponseDecodesUpdatedRollingSummary() throws {
        let raw = #"{"matches":[{"issueIndex":0,"trackingID":null,"reopen":false,"reason":"首次出现","updatedSummary":"首版综合档案","aliases":["SEP"],"searchTerms":["病毒误报"],"negativeTerms":["USB管控"]}]}"#
        let output = try XCTUnwrap(IssueAssociationService.parse(raw))
        XCTAssertEqual(output.matches.first?.updatedSummary, "首版综合档案")
        XCTAssertEqual(output.matches.first?.searchTerms, ["病毒误报"])
    }

    func testIssueAssociationCandidateContextUsesBoundedRollingProfile() {
        let issue = candidateIssue(index: 1, title: "内核兼容问题")
        let context = IssueAssociationService.compactCandidate(
            issue, rollingProfile: String(repeating: "综合档案内容", count: 100))

        XCTAssertTrue(context.contains("综合档案摘要"))
        XCTAssertTrue(context.contains("…"))
        XCTAssertFalse(context.contains("当前背景"))
        XCTAssertLessThan(context.count, 700)
    }

    func testRetrievalProfileIsAppliedWithoutAcceptingIssueProposal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrieval-profile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let workspaceID = UUID()
        let issue = candidateIssue(index: 1, title: "杀毒软件误报")
        var stored = issue
        stored.workspaceID = workspaceID
        stored.searchTerms = ["历史稳定词"]
        stored.negativeTerms = ["历史排除词"]
        try ProjectLedgerStore.save(ProjectLedger(issues: [stored]), to: url)
        let proposed = StructuredMinutes.Issue(
            trackingID: stored.id, rollingSummary: "最新综合档案",
            proposedAliases: ["SEP"], proposedSearchTerms: ["病毒告警", "样本字符串"],
            proposedNegativeTerms: ["USB管控"], title: stored.title, status: "进行中",
            rootCause: "", solution: "", progress: "", evidence: [])
        let minutes = StructuredMinutes(
            title: "周会", nature: "", duration: "", agenda: [], participantAssessment: [],
            issues: [proposed], requirements: [], actionItems: [], agreements: [],
            afterMeeting: [], uncertainties: [])
        let record = MeetingRecord(
            title: "周会", sourcePath: "/tmp/source.mov", duration: 60,
            backend: "测试", model: "mock", summaryMarkdown: "", structuredSummary: minutes,
            transcript: Transcript(segments: []), speakerNames: [:], usedSummaryFallback: false,
            workspaceID: workspaceID)

        let ledger = try ProjectLedgerStore.applyRetrievalProfiles(for: record, at: url)

        XCTAssertEqual(ledger.issues[0].aliases, ["SEP"])
        XCTAssertEqual(ledger.issues[0].searchTerms, ["历史稳定词", "病毒告警", "样本字符串"])
        XCTAssertEqual(ledger.issues[0].negativeTerms, ["历史排除词", "USB管控"])
        XCTAssertEqual(ledger.analysis(for: stored.id)?.summary, "最新综合档案")
        XCTAssertTrue(ledger.issueProposals.isEmpty)
    }

    func testClosedIssueIsNotRestoredByLocalFallbackWithoutExplicitReopen() {
        var closed = candidateIssue(index: 1, title: "Agent组件病毒误报")
        closed.status = "已闭环"
        var minutes = StructuredMinutes(
            title: "周会", nature: "", duration: "", agenda: [], participantAssessment: [],
            issues: [.init(title: "Agent组件病毒误报", status: "待确认", background: "",
                           rootCause: "", solution: "", progress: "", evidence: [])],
            requirements: [], actionItems: [], agreements: [], afterMeeting: [], uncertainties: [])

        IssueTracking.prepare(&minutes, confirmedIssues: [closed])

        XCTAssertNotEqual(minutes.issues[0].trackingID, closed.id)
    }

    private func candidateIssue(index: Int, title: String) -> ProjectIssue {
        ProjectIssue(
            id: "MS-ISSUE-\(index)", workspaceID: UUID(), title: title, aliases: [],
            background: "项目背景 \(index)", rootCause: "原因 \(index)", solution: "方案 \(index)",
            status: "进行中", createdAt: Date(timeIntervalSince1970: Double(index)),
            updatedAt: Date(timeIntervalSince1970: Double(index)), sourceMeetingID: UUID(), events: [])
    }

    func testIssueTrackingResolvesNewIssueTitleReferenceForAction() {
        var minutes = StructuredMinutes(
            title: "周会", nature: "", duration: "", agenda: [], participantAssessment: [],
            issues: [.init(title: "日志积压", status: "进行中", background: "",
                           rootCause: "待查", solution: "扩容", progress: "", evidence: [])],
            requirements: [],
            actionItems: [.init(issueID: "日志积压", owner: "张三", task: "提交扩容方案",
                                status: "待执行", due: "", evidence: [])],
            agreements: [], afterMeeting: [], uncertainties: [])

        IssueTracking.prepare(&minutes, confirmedIssues: [])

        XCTAssertNotNil(minutes.issues[0].trackingID)
        XCTAssertEqual(minutes.actionItems[0].issueID, minutes.issues[0].trackingID)
    }

    func testRemovingMeetingPrunesOnlyPendingLedgerReferences() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prune-meeting-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let meetingID = UUID(), workspaceID = UUID()
        let pending = ProjectIssueProposal(
            workspaceID: workspaceID, meetingID: meetingID, meetingTitle: "会议",
            meetingDate: Date(), kind: .create, targetIssueID: nil, title: "问题",
            background: "", rootCause: "", solution: "", progress: "", status: "进行中",
            previousStatus: nil, evidence: [])
        var accepted = pending
        accepted.id = UUID(); accepted.resolution = .accepted
        try ProjectLedgerStore.save(ProjectLedger(issueProposals: [pending, accepted]), to: url)

        let ledger = try ProjectLedgerStore.removePendingReferences(to: [meetingID], at: url)
        XCTAssertEqual(ledger.issueProposals.map(\.id), [accepted.id])
        XCTAssertEqual(ledger.issueProposals.first?.resolution, .accepted)
    }

    func testIssueStatusCanBeClosedAndReopenedWithAuditEvents() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let issue = ProjectIssue(
            id: "MS-ISSUE-STATUS", workspaceID: UUID(), title: "持续问题", aliases: [],
            background: "背景", rootCause: "根因", solution: "方案", status: "进行中",
            createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100),
            sourceMeetingID: UUID(), events: [])
        try ProjectLedgerStore.save(ProjectLedger(issues: [issue]), to: url)

        var ledger = try ProjectLedgerStore.updateIssueStatus(
            issueID: issue.id, status: "已闭环", note: "现场验证通过", at: url)
        XCTAssertTrue(ledger.issues[0].isClosed)
        XCTAssertEqual(ledger.issues[0].events.last?.note, "现场验证通过")

        ledger = try ProjectLedgerStore.updateIssueStatus(
            issueID: issue.id, status: "进行中", note: "客户要求重新打开", at: url)
        XCTAssertFalse(ledger.issues[0].isClosed)
        XCTAssertEqual(ledger.issues[0].events.last?.previousStatus, "已闭环")
    }

    func testLegacyProjectLedgerDecodesWithoutIssueCollections() throws {
        let data = #"{"actions":[],"proposals":[]}"#.data(using: .utf8)!
        let ledger = try JSONDecoder().decode(ProjectLedger.self, from: data)
        XCTAssertTrue(ledger.issues.isEmpty)
        XCTAssertTrue(ledger.issueProposals.isEmpty)
    }
    func testActionTrackingSuggestsOnlyExactEvidenceBackedStatusChanges() {
        let workspaceID = UUID()
        let oldMinutes = StructuredMinutes(
            title: "上期", nature: "", duration: "", agenda: ["进展"],
            participantAssessment: [], issues: [], requirements: [],
            actionItems: [.init(owner: "张三", task: "提交上线方案", status: "进行中",
                                due: "", evidence: [])],
            agreements: [], afterMeeting: [], uncertainties: [])
        let old = MeetingRecord(
            title: "上期", sourcePath: "/old.mov", duration: 10,
            backend: "测试", model: "mock", summaryMarkdown: "纪要",
            structuredSummary: oldMinutes, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false, workspaceID: workspaceID)
        var current = StructuredMinutes(
            title: "本期", nature: "", duration: "", agenda: ["进展"],
            participantAssessment: [], issues: [], requirements: [],
            actionItems: [
                .init(owner: "张三", task: "提交上线方案", status: "已完成",
                      due: "", evidence: ["[08:20]"]),
                .init(owner: "李四", task: "确认名单", status: "已完成",
                      due: "", evidence: []),
            ], agreements: [], afterMeeting: [], uncertainties: [])

        let suggestions = ActionTracking.prepare(&current, priorRecords: [old])
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].task, "提交上线方案")
        XCTAssertEqual(suggestions[0].proposedStatus, "已完成")
        XCTAssertEqual(current.actionItems[0].trackingID, suggestions[0].targetActionID)
        XCTAssertNotNil(current.actionItems[1].trackingID)
    }
    func testWorkspaceRoundTripPreservesContext() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-workspaces-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var workspace = MeetingWorkspace(name: "某客户", kind: .customer,
                                         context: "我方是安全产品厂商")
        workspace.defaultTemplateID = MinutesTemplate.customer.id
        workspace.defaultEmailTemplateID = EmailTemplate.customer.id

        try MeetingWorkspaceStore.save([workspace], to: url)
        let loaded = try MeetingWorkspaceStore.load(from: url)
        XCTAssertEqual(loaded.first?.id, workspace.id)
        XCTAssertEqual(loaded.first?.context, "我方是安全产品厂商")
        XCTAssertEqual(loaded.first?.defaultTemplateID, MinutesTemplate.customer.id)
        XCTAssertEqual(loaded.first?.defaultEmailTemplateID, EmailTemplate.customer.id)
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

    @MainActor
    func testLearnedAndManualVocabularySurviveWhisperPromptLimit() {
        let legacy = String(repeating: "通", count: 155) + "无相AI"
        let prompt = PipelineRunner.transcriptionPrompt(
            scenario: .hongKongMixed,
            priorityVocabulary: "(无线AI)应识别为(无相AI)",
            glossary: legacy,
            materials: [])
        let trimmed = Transcriber.trimGlossary(prompt)

        XCTAssertTrue(trimmed.hasPrefix("(无线AI)应识别为(无相AI)"))
        XCTAssertTrue(trimmed.contains("无相AI"))
        XCTAssertLessThanOrEqual(trimmed.count, 170)
    }

    @MainActor
    func testWhisperPromptRemovesMarkdownInstructionsAndInlineComments() {
        let prompt = PipelineRunner.transcriptionPrompt(
            scenario: .mandarin,
            priorityVocabulary: "无线AI应识别为无相AI # 领域词表说明\n# 不应发送给模型",
            glossary: "Agent\n# 使用说明",
            materials: [])

        XCTAssertTrue(prompt.contains("无线AI应识别为无相AI"))
        XCTAssertTrue(prompt.contains("Agent"))
        XCTAssertFalse(prompt.contains("#"))
        XCTAssertFalse(prompt.contains("领域词表说明"))
    }

    func testWorkspaceInsightsAggregatesOpenAndClosedActions() {
        func record(status: String, task: String) -> MeetingRecord {
            let minutes = StructuredMinutes(
                title: "周会", nature: "", duration: "", agenda: ["进展"],
                participantAssessment: [], issues: [], requirements: [],
                actionItems: [.init(owner: "张三", task: task, status: status,
                                    due: "周五", evidence: ["[01:00]"])],
                agreements: [], afterMeeting: [], uncertainties: [])
            return MeetingRecord(
                title: "项目周会", sourcePath: "/meeting.mov", duration: 60,
                backend: "测试", model: "mock", summaryMarkdown: "纪要",
                structuredSummary: minutes, transcript: Transcript(segments: []),
                speakerNames: [:], usedSummaryFallback: false)
        }

        let insights = WorkspaceInsights(records: [
            record(status: "进行中", task: "提交方案"),
            record(status: "已完成", task: "确认名单"),
        ])
        XCTAssertEqual(insights.actions.count, 2)
        XCTAssertEqual(insights.openActions.map(\.task), ["提交方案"])
        XCTAssertEqual(insights.closedActions.map(\.task), ["确认名单"])
    }

    func testWorkspaceInsightsKeepsLatestActionStateWithoutDuplicatingLedger() {
        func record(date: Date, status: String) -> MeetingRecord {
            let minutes = StructuredMinutes(
                title: "周会", nature: "", duration: "", agenda: ["进展"],
                participantAssessment: [], issues: [], requirements: [],
                actionItems: [.init(owner: "张三", task: "提交实施方案", status: status,
                                    due: "周五", evidence: [])],
                agreements: [], afterMeeting: [], uncertainties: [])
            return MeetingRecord(createdAt: date, title: "项目周会", sourcePath: "/meeting.mov",
                                 duration: 60, backend: "测试", model: "mock",
                                 summaryMarkdown: "纪要", structuredSummary: minutes,
                                 transcript: Transcript(segments: []), speakerNames: [:],
                                 usedSummaryFallback: false)
        }

        let insights = WorkspaceInsights(records: [
            record(date: Date(timeIntervalSince1970: 100), status: "进行中"),
            record(date: Date(timeIntervalSince1970: 200), status: "已完成"),
        ])
        XCTAssertEqual(insights.actions.count, 2)
        XCTAssertTrue(insights.openActions.isEmpty)
        XCTAssertEqual(insights.closedActions.count, 1)
        XCTAssertEqual(insights.closedActions.first?.status, "已完成")
        XCTAssertFalse(WorkspaceInsights.isClosed(status: "未完成"))
        XCTAssertFalse(WorkspaceInsights.isClosed(status: "待解决"))
        XCTAssertTrue(WorkspaceInsights.isClosed(status: "已解决"))
    }

    func testWorkspaceInsightsComparesLatestMeetingsWithoutTreatingOmissionAsClosed() throws {
        func record(date: Date, issues: [StructuredMinutes.Issue],
                    requirements: [StructuredMinutes.Requirement],
                    actions: [StructuredMinutes.ActionItem]) -> MeetingRecord {
            let minutes = StructuredMinutes(
                title: "双周会", nature: "", duration: "", agenda: ["进展"],
                participantAssessment: [], issues: issues, requirements: requirements,
                actionItems: actions, agreements: [], afterMeeting: [], uncertainties: [])
            return MeetingRecord(createdAt: date, title: "双周会", sourcePath: "/meeting.mov",
                                 duration: 60, backend: "测试", model: "mock",
                                 summaryMarkdown: "纪要", structuredSummary: minutes,
                                 transcript: Transcript(segments: []), speakerNames: [:],
                                 usedSummaryFallback: false)
        }

        let old = record(
            date: Date(timeIntervalSince1970: 100),
            issues: [
                .init(title: "登录超时", status: "处理中", rootCause: "", solution: "",
                      progress: "", evidence: []),
                .init(title: "报表错误", status: "处理中", rootCause: "", solution: "",
                      progress: "", evidence: []),
            ],
            requirements: [],
            actions: [.init(owner: "李四", task: "确认上线窗口", status: "未开始",
                            due: "", evidence: [])])
        let current = record(
            date: Date(timeIntervalSince1970: 200),
            issues: [
                .init(title: "登录超时", status: "已解决", rootCause: "", solution: "",
                      progress: "", evidence: []),
                .init(title: "新增告警", status: "处理中", rootCause: "", solution: "",
                      progress: "", evidence: []),
            ],
            requirements: [.init(title: "增加审计报表", status: "待评估", schedule: "",
                                 evidence: [])],
            actions: [.init(owner: "李四", task: "确认上线窗口", status: "进行中",
                            due: "", evidence: [])])

        let changes = try XCTUnwrap(WorkspaceInsights(records: [old, current]).latestChanges)
        XCTAssertEqual(changes.currentMeeting.createdAt, current.createdAt)
        XCTAssertEqual(changes.items(of: .closed).map(\.title), ["登录超时"])
        XCTAssertEqual(Set(changes.items(of: .new).map(\.title)), ["新增告警", "增加审计报表"])
        XCTAssertEqual(changes.items(of: .statusChanged).map(\.title), ["确认上线窗口"])
        XCTAssertEqual(changes.items(of: .notMentioned).map(\.title), ["报表错误"])
    }
}
