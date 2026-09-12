import Foundation

enum ProjectLedgerStore {
    enum Failure: LocalizedError {
        case proposalNotFound, actionNotFound, duplicateIssueID
        var errorDescription: String? {
            switch self {
            case .proposalNotFound: "找不到这条项目更新建议。"
            case .actionNotFound: "建议关联的项目行动项不存在。"
            case .duplicateIssueID: "项目问题 ID 已存在，无法重复创建。"
            }
        }
    }

    static let fileURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingScribe/project-ledger.json")

    static func load(from url: URL = fileURL) throws -> ProjectLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return ProjectLedger() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectLedger.self, from: Data(contentsOf: url))
    }

    static func save(_ ledger: ProjectLedger, to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(ledger).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @discardableResult
    static func saveIssueAnalysis(issue: ProjectIssue,
                                  report: ProjectIssueAnalysisService.Report,
                                  at url: URL = fileURL) throws -> ProjectLedger {
        var ledger = try load(from: url)
        let analysis = ProjectIssueAnalysis(
            issueID: issue.id, workspaceID: issue.workspaceID,
            summary: report.summary,
            timeline: report.timeline.map {
                .init(date: $0.date, meetingTitle: $0.meetingTitle, change: $0.change)
            },
            generatedAt: Date(), sourceEventIDs: issue.events.map(\.id))
        if let index = ledger.issueAnalyses.firstIndex(where: { $0.issueID == issue.id }) {
            ledger.issueAnalyses[index] = analysis
        } else {
            ledger.issueAnalyses.append(analysis)
        }
        try save(ledger, to: url)
        return ledger
    }

    @discardableResult
    static func prepareProposals(for record: MeetingRecord,
                                 at url: URL = fileURL) throws -> ProjectLedger {
        guard let workspaceID = record.workspaceID,
              let structured = record.structuredSummary else { return try load(from: url) }
        var ledger = try load(from: url)
        // Action items are meeting facts, not a second task-management ledger. Remove any
        // still-pending legacy action proposals and keep project confirmation for issues only.
        ledger.proposals.removeAll { $0.workspaceID == workspaceID && $0.resolution == .pending }
        ledger.issueProposals.removeAll {
            $0.meetingID == record.id && $0.resolution == .pending
        }
        for issue in structured.issues where !issue.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let target = ledger.issues.first { $0.id == issue.trackingID }
            if let target {
                let changed = target.title != issue.title || target.status != issue.status
                    || (!issue.rootCause.isEmpty && target.rootCause != issue.rootCause)
                    || (!issue.solution.isEmpty && target.solution != issue.solution)
                    || (!issue.progress.isEmpty)
                guard changed, !issue.evidence.isEmpty else { continue }
                ledger.issueProposals.append(.init(
                    workspaceID: workspaceID, meetingID: record.id,
                    meetingTitle: record.title, meetingDate: record.createdAt,
                    kind: .update, targetIssueID: target.id, title: issue.title,
                    background: issue.background ?? "", rootCause: issue.rootCause,
                    solution: issue.solution, progress: issue.progress, status: issue.status,
                    previousStatus: target.status, evidence: issue.evidence,
                    rollingSummary: issue.rollingSummary,
                    proposedAliases: issue.proposedAliases,
                    proposedSearchTerms: issue.proposedSearchTerms,
                    proposedNegativeTerms: issue.proposedNegativeTerms))
            } else {
                guard !issue.evidence.isEmpty else { continue }
                ledger.issueProposals.append(.init(
                    workspaceID: workspaceID, meetingID: record.id,
                    meetingTitle: record.title, meetingDate: record.createdAt,
                    kind: .create, targetIssueID: issue.trackingID,
                    title: issue.title, background: issue.background ?? "",
                    rootCause: issue.rootCause, solution: issue.solution,
                    progress: issue.progress, status: issue.status,
                    previousStatus: nil, evidence: issue.evidence,
                    rollingSummary: issue.rollingSummary,
                    proposedAliases: issue.proposedAliases,
                    proposedSearchTerms: issue.proposedSearchTerms,
                    proposedNegativeTerms: issue.proposedNegativeTerms))
            }
        }
        try save(ledger, to: url)
        return ledger
    }

    /// Retrieval metadata is system-maintained and has no customer-facing effect, so it is
    /// applied automatically once the meeting itself has passed issue association/review.
    @discardableResult
    static func applyRetrievalProfiles(for record: MeetingRecord,
                                       at url: URL = fileURL) throws -> ProjectLedger {
        guard let structured = record.structuredSummary else { return try load(from: url) }
        var ledger = try load(from: url)
        var changed = false
        for proposed in structured.issues {
            guard let id = proposed.trackingID,
                  let index = ledger.issues.firstIndex(where: { $0.id == id }) else { continue }
            if let aliases = proposed.proposedAliases {
                ledger.issues[index].aliases = mergedTerms(ledger.issues[index].aliases, aliases)
                changed = true
            }
            if let terms = proposed.proposedSearchTerms {
                ledger.issues[index].searchTerms = mergedTerms(
                    ledger.issues[index].searchTerms ?? [], terms)
                changed = true
            }
            if let terms = proposed.proposedNegativeTerms {
                ledger.issues[index].negativeTerms = mergedTerms(
                    ledger.issues[index].negativeTerms ?? [], terms)
                changed = true
            }
            if let summary = proposed.rollingSummary?
                .trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                let issue = ledger.issues[index]
                let previous = ledger.analysis(for: id)
                let analysis = ProjectIssueAnalysis(
                    issueID: id, workspaceID: issue.workspaceID, summary: summary,
                    timeline: previous?.timeline ?? [], generatedAt: Date(),
                    sourceEventIDs: issue.events.map(\.id))
                if let analysisIndex = ledger.issueAnalyses.firstIndex(where: { $0.issueID == id }) {
                    ledger.issueAnalyses[analysisIndex] = analysis
                } else {
                    ledger.issueAnalyses.append(analysis)
                }
                changed = true
            }
        }
        if changed { try save(ledger, to: url) }
        return ledger
    }

    @discardableResult
    static func accept(proposalID: UUID, edited: ProjectActionProposal? = nil,
                       at url: URL = fileURL) throws -> ProjectLedger {
        var ledger = try load(from: url)
        guard let proposalIndex = ledger.proposals.firstIndex(where: { $0.id == proposalID })
        else { throw Failure.proposalNotFound }
        let proposal = edited ?? ledger.proposals[proposalIndex]
        switch proposal.kind {
        case .create:
            let id = proposal.targetActionID ?? "PA-\(UUID().uuidString.uppercased())"
            let event = event(for: proposal, kind: .created, previousStatus: nil)
            ledger.actions.append(ProjectAction(
                id: id, workspaceID: proposal.workspaceID, issueID: proposal.issueID,
                task: proposal.task,
                owner: proposal.owner, status: proposal.status, due: proposal.due,
                createdAt: proposal.meetingDate, updatedAt: proposal.meetingDate,
                sourceMeetingID: proposal.meetingID, events: [event]))
        case .update:
            guard let targetID = proposal.targetActionID,
                  let actionIndex = ledger.actions.firstIndex(where: { $0.id == targetID })
            else { throw Failure.actionNotFound }
            let previous = ledger.actions[actionIndex].status
            ledger.actions[actionIndex].issueID = proposal.issueID
            ledger.actions[actionIndex].task = proposal.task
            ledger.actions[actionIndex].owner = proposal.owner
            ledger.actions[actionIndex].status = proposal.status
            ledger.actions[actionIndex].due = proposal.due
            ledger.actions[actionIndex].updatedAt = proposal.meetingDate
            ledger.actions[actionIndex].events.append(event(for: proposal, kind: .updated,
                                                            previousStatus: previous))
        }
        ledger.proposals[proposalIndex].resolution = .accepted
        try save(ledger, to: url)
        return ledger
    }

    @discardableResult
    static func ignore(proposalID: UUID, at url: URL = fileURL) throws -> ProjectLedger {
        var ledger = try load(from: url)
        guard let index = ledger.proposals.firstIndex(where: { $0.id == proposalID })
        else { throw Failure.proposalNotFound }
        ledger.proposals[index].resolution = .ignored
        try save(ledger, to: url)
        return ledger
    }

    /// Applies a selection as one atomic ledger write. If any proposal is invalid,
    /// nothing is persisted, preventing a half-confirmed batch.
    @discardableResult
    static func accept(proposalIDs: Set<UUID>, at url: URL = fileURL) throws -> ProjectLedger {
        var ledger = try load(from: url)
        for proposalID in proposalIDs {
            try accept(proposalID: proposalID, in: &ledger)
        }
        try save(ledger, to: url)
        return ledger
    }

    @discardableResult
    static func ignore(proposalIDs: Set<UUID>, at url: URL = fileURL) throws -> ProjectLedger {
        var ledger = try load(from: url)
        for proposalID in proposalIDs {
            guard let index = ledger.proposals.firstIndex(where: { $0.id == proposalID })
            else { throw Failure.proposalNotFound }
            ledger.proposals[index].resolution = .ignored
        }
        try save(ledger, to: url)
        return ledger
    }

    @discardableResult
    static func acceptIssue(proposalID: UUID, targetIssueID: String? = nil,
                            createNew: Bool = false,
                            at url: URL = fileURL) throws -> ProjectLedger {
        var ledger = try load(from: url)
        guard let proposalIndex = ledger.issueProposals.firstIndex(where: { $0.id == proposalID })
        else { throw Failure.proposalNotFound }
        var proposal = ledger.issueProposals[proposalIndex]
        if createNew {
            proposal.kind = .create
            proposal.targetIssueID = nil
            proposal.previousStatus = nil
        } else if let targetIssueID {
            guard let target = ledger.issues.first(where: { $0.id == targetIssueID })
            else { throw Failure.actionNotFound }
            proposal.kind = .update
            proposal.targetIssueID = targetIssueID
            proposal.previousStatus = target.status
        }
        switch proposal.kind {
        case .create:
            let id = proposal.targetIssueID ?? "MS-ISSUE-\(UUID().uuidString.uppercased())"
            guard !ledger.issues.contains(where: { $0.id == id })
            else { throw Failure.duplicateIssueID }
            proposal.targetIssueID = id
            ledger.issues.append(ProjectIssue(
                id: id, workspaceID: proposal.workspaceID, title: proposal.title,
                aliases: normalizedTerms(proposal.proposedAliases ?? []),
                searchTerms: normalizedTerms(proposal.proposedSearchTerms ?? []),
                negativeTerms: normalizedTerms(proposal.proposedNegativeTerms ?? []),
                background: proposal.background, rootCause: proposal.rootCause,
                solution: proposal.solution, status: proposal.status,
                createdAt: proposal.meetingDate, updatedAt: proposal.meetingDate,
                sourceMeetingID: proposal.meetingID,
                events: [issueEvent(for: proposal, kind: .created, previousStatus: nil)]))
        case .update:
            guard let targetID = proposal.targetIssueID,
                  let index = ledger.issues.firstIndex(where: { $0.id == targetID })
            else { throw Failure.actionNotFound }
            let previous = ledger.issues[index].status
            if proposal.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                proposal.status = previous
            }
            if ledger.issues[index].title != proposal.title,
               !ledger.issues[index].aliases.contains(ledger.issues[index].title) {
                ledger.issues[index].aliases.append(ledger.issues[index].title)
            }
            ledger.issues[index].title = proposal.title
            ledger.issues[index].aliases = mergedTerms(
                ledger.issues[index].aliases, proposal.proposedAliases ?? [])
            if let terms = proposal.proposedSearchTerms {
                ledger.issues[index].searchTerms = mergedTerms(
                    ledger.issues[index].searchTerms ?? [], terms)
            }
            if let terms = proposal.proposedNegativeTerms {
                ledger.issues[index].negativeTerms = mergedTerms(
                    ledger.issues[index].negativeTerms ?? [], terms)
            }
            if !proposal.background.isEmpty { ledger.issues[index].background = proposal.background }
            if !proposal.rootCause.isEmpty { ledger.issues[index].rootCause = proposal.rootCause }
            if !proposal.solution.isEmpty { ledger.issues[index].solution = proposal.solution }
            ledger.issues[index].status = proposal.status
            ledger.issues[index].updatedAt = proposal.meetingDate
            let kind: ProjectIssueEvent.Kind = WorkspaceInsights.isClosed(status: proposal.status)
                ? .closed : .updated
            ledger.issues[index].events.append(issueEvent(for: proposal, kind: kind,
                                                          previousStatus: previous))
        }
        proposal.resolution = .accepted
        ledger.issueProposals[proposalIndex] = proposal
        if let issueID = proposal.targetIssueID,
           let issue = ledger.issues.first(where: { $0.id == issueID }) {
            updateRollingAnalysis(for: issue, proposal: proposal, in: &ledger)
        }
        try save(ledger, to: url)
        return ledger
    }

    @discardableResult
    static func reopenIssue(proposalID: UUID, at url: URL = fileURL) throws -> ProjectLedger {
        var ledger = try load(from: url)
        guard let proposalIndex = ledger.issueProposals.firstIndex(where: { $0.id == proposalID })
        else { throw Failure.proposalNotFound }
        let proposal = ledger.issueProposals[proposalIndex]
        guard proposal.resolution == .accepted else { return ledger }
        if let targetID = proposal.targetIssueID,
           let issueIndex = ledger.issues.firstIndex(where: { $0.id == targetID }) {
            ledger.issues[issueIndex].events.removeAll {
                $0.meetingID == proposal.meetingID
                    && $0.occurredAt == proposal.meetingDate
                    && $0.title == proposal.title
            }
            if ledger.issues[issueIndex].events.isEmpty {
                ledger.issues.remove(at: issueIndex)
            } else {
                rebuildIssue(at: issueIndex, in: &ledger)
            }
        }
        ledger.issueProposals[proposalIndex].resolution = .pending
        try save(ledger, to: url)
        return ledger
    }

    @discardableResult
    static func ignoreIssue(proposalID: UUID, at url: URL = fileURL) throws -> ProjectLedger {
        var ledger = try load(from: url)
        guard let index = ledger.issueProposals.firstIndex(where: { $0.id == proposalID })
        else { throw Failure.proposalNotFound }
        ledger.issueProposals[index].resolution = .ignored
        try save(ledger, to: url)
        return ledger
    }

    @discardableResult
    static func removePendingReferences(to meetingIDs: Set<UUID>,
                                        at url: URL = fileURL) throws -> ProjectLedger {
        guard !meetingIDs.isEmpty else { return try load(from: url) }
        var ledger = try load(from: url)
        ledger.proposals.removeAll {
            meetingIDs.contains($0.meetingID) && $0.resolution == .pending
        }
        ledger.issueProposals.removeAll {
            meetingIDs.contains($0.meetingID) && $0.resolution == .pending
        }
        try save(ledger, to: url)
        return ledger
    }

    @discardableResult
    static func updateIssueStatus(issueID: String, status: String, note: String,
                                  at url: URL = fileURL) throws -> ProjectLedger {
        var ledger = try load(from: url)
        guard let index = ledger.issues.firstIndex(where: { $0.id == issueID })
        else { throw Failure.actionNotFound }
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return ledger }
        let previous = ledger.issues[index].status
        guard previous != value else { return ledger }
        let now = Date()
        ledger.issues[index].status = value
        ledger.issues[index].updatedAt = now
        let issue = ledger.issues[index]
        ledger.issues[index].events.append(ProjectIssueEvent(
            kind: WorkspaceInsights.isClosed(status: value) ? .closed : .updated,
            occurredAt: now, meetingID: issue.sourceMeetingID, meetingTitle: "手动状态调整",
            previousStatus: previous, currentStatus: value, title: issue.title,
            background: issue.background, rootCause: issue.rootCause, solution: issue.solution,
            progress: note.isEmpty ? "手动将问题状态调整为“\(value)”" : note,
            evidence: [], note: note.isEmpty ? nil : note))
        try save(ledger, to: url)
        return ledger
    }

    private static func event(for proposal: ProjectActionProposal, kind: ProjectActionEvent.Kind,
                              previousStatus: String?) -> ProjectActionEvent {
        ProjectActionEvent(kind: kind, occurredAt: proposal.meetingDate,
                           meetingID: proposal.meetingID, meetingTitle: proposal.meetingTitle,
                           issueID: proposal.issueID,
                           previousStatus: previousStatus, currentStatus: proposal.status,
                           owner: proposal.owner, due: proposal.due, evidence: proposal.evidence)
    }

    private static func accept(proposalID: UUID, in ledger: inout ProjectLedger) throws {
        guard let proposalIndex = ledger.proposals.firstIndex(where: { $0.id == proposalID })
        else { throw Failure.proposalNotFound }
        let proposal = ledger.proposals[proposalIndex]
        switch proposal.kind {
        case .create:
            let id = proposal.targetActionID ?? "PA-\(UUID().uuidString.uppercased())"
            ledger.actions.append(ProjectAction(
                id: id, workspaceID: proposal.workspaceID, issueID: proposal.issueID,
                task: proposal.task, owner: proposal.owner, status: proposal.status,
                due: proposal.due, createdAt: proposal.meetingDate,
                updatedAt: proposal.meetingDate, sourceMeetingID: proposal.meetingID,
                events: [event(for: proposal, kind: .created, previousStatus: nil)]))
        case .update:
            guard let targetID = proposal.targetActionID,
                  let actionIndex = ledger.actions.firstIndex(where: { $0.id == targetID })
            else { throw Failure.actionNotFound }
            let previous = ledger.actions[actionIndex].status
            ledger.actions[actionIndex].issueID = proposal.issueID
            ledger.actions[actionIndex].task = proposal.task
            ledger.actions[actionIndex].owner = proposal.owner
            ledger.actions[actionIndex].status = proposal.status
            ledger.actions[actionIndex].due = proposal.due
            ledger.actions[actionIndex].updatedAt = proposal.meetingDate
            ledger.actions[actionIndex].events.append(event(
                for: proposal, kind: .updated, previousStatus: previous))
        }
        ledger.proposals[proposalIndex].resolution = .accepted
    }

    private static func issueEvent(for proposal: ProjectIssueProposal,
                                   kind: ProjectIssueEvent.Kind,
                                   previousStatus: String?) -> ProjectIssueEvent {
        ProjectIssueEvent(kind: kind, occurredAt: proposal.meetingDate,
                          meetingID: proposal.meetingID, meetingTitle: proposal.meetingTitle,
                          previousStatus: previousStatus, currentStatus: proposal.status,
                          title: proposal.title, background: proposal.background,
                          rootCause: proposal.rootCause, solution: proposal.solution,
                          progress: proposal.progress, evidence: proposal.evidence)
    }

    private static func updateRollingAnalysis(for issue: ProjectIssue,
                                              proposal: ProjectIssueProposal,
                                              in ledger: inout ProjectLedger) {
        let proposed = proposal.rollingSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = [proposal.background, proposal.rootCause, proposal.solution, proposal.progress]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "；")
        let summary = proposed.isEmpty ? fallback : proposed
        guard !summary.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        let change = proposal.progress.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = ProjectIssueAnalysis.TimelineItem(
            date: formatter.string(from: proposal.meetingDate),
            meetingTitle: proposal.meetingTitle,
            change: change.isEmpty ? "本次会议更新了问题状态和处置信息" : change)
        var timeline = ledger.analysis(for: issue.id)?.timeline ?? []
        if !timeline.contains(where: {
            $0.date == item.date && $0.meetingTitle == item.meetingTitle && $0.change == item.change
        }) { timeline.append(item) }
        timeline.sort { $0.date == $1.date ? $0.meetingTitle < $1.meetingTitle : $0.date < $1.date }
        let analysis = ProjectIssueAnalysis(
            issueID: issue.id, workspaceID: issue.workspaceID,
            summary: summary, timeline: timeline, generatedAt: Date(),
            sourceEventIDs: issue.events.map(\.id))
        if let index = ledger.issueAnalyses.firstIndex(where: { $0.issueID == issue.id }) {
            ledger.issueAnalyses[index] = analysis
        } else {
            ledger.issueAnalyses.append(analysis)
        }
    }

    private static func mergedTerms(_ existing: [String], _ proposed: [String]) -> [String] {
        normalizedTerms(existing + proposed)
    }

    private static func normalizedTerms(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = cleaned.lowercased()
            guard cleaned.count >= 2, cleaned.count <= 50, seen.insert(key).inserted else { return nil }
            return cleaned
        }.prefix(24).map { $0 }
    }

    private static func rebuildIssue(at index: Int, in ledger: inout ProjectLedger) {
        let events = ledger.issues[index].events.sorted { $0.occurredAt < $1.occurredAt }
        guard let first = events.first, let latest = events.last else { return }
        ledger.issues[index].events = events
        ledger.issues[index].createdAt = first.occurredAt
        ledger.issues[index].updatedAt = latest.occurredAt
        ledger.issues[index].sourceMeetingID = first.meetingID
        ledger.issues[index].title = latest.title
        ledger.issues[index].status = latest.currentStatus
        ledger.issues[index].background = events.reversed().first { !$0.background.isEmpty }?.background ?? ""
        ledger.issues[index].rootCause = events.reversed().first { !$0.rootCause.isEmpty }?.rootCause ?? ""
        ledger.issues[index].solution = events.reversed().first { !$0.solution.isEmpty }?.solution ?? ""
    }
}
