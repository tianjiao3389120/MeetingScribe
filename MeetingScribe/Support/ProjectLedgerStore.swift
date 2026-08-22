import Foundation

enum ProjectLedgerStore {
    enum Failure: LocalizedError {
        case proposalNotFound, actionNotFound
        var errorDescription: String? {
            switch self {
            case .proposalNotFound: "找不到这条项目更新建议。"
            case .actionNotFound: "建议关联的项目行动项不存在。"
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
    static func prepareProposals(for record: MeetingRecord,
                                 at url: URL = fileURL) throws -> ProjectLedger {
        guard let workspaceID = record.workspaceID,
              let actions = record.structuredSummary?.actionItems else { return try load(from: url) }
        var ledger = try load(from: url)
        ledger.proposals.removeAll { $0.meetingID == record.id && $0.resolution == .pending }
        for action in actions where !action.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trackingID = action.trackingID
            let target = ledger.actions.first { item in
                (trackingID != nil && item.id == trackingID)
                    || ActionTracking.identity(item.task) == ActionTracking.identity(action.task)
            }
            if let target {
                let changed = target.task != action.task || target.owner != action.owner
                    || target.status != action.status || target.due != action.due
                guard changed, !action.evidence.isEmpty else { continue }
                ledger.proposals.append(.init(
                    workspaceID: workspaceID, meetingID: record.id, meetingTitle: record.title,
                    meetingDate: record.createdAt, kind: .update, targetActionID: target.id,
                    task: action.task, owner: action.owner, status: action.status, due: action.due,
                    previousStatus: target.status, evidence: action.evidence))
            } else {
                ledger.proposals.append(.init(
                    workspaceID: workspaceID, meetingID: record.id, meetingTitle: record.title,
                    meetingDate: record.createdAt, kind: .create,
                    targetActionID: trackingID, task: action.task, owner: action.owner,
                    status: action.status, due: action.due, previousStatus: nil,
                    evidence: action.evidence))
            }
        }
        try save(ledger, to: url)
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
                id: id, workspaceID: proposal.workspaceID, task: proposal.task,
                owner: proposal.owner, status: proposal.status, due: proposal.due,
                createdAt: proposal.meetingDate, updatedAt: proposal.meetingDate,
                sourceMeetingID: proposal.meetingID, events: [event]))
        case .update:
            guard let targetID = proposal.targetActionID,
                  let actionIndex = ledger.actions.firstIndex(where: { $0.id == targetID })
            else { throw Failure.actionNotFound }
            let previous = ledger.actions[actionIndex].status
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

    private static func event(for proposal: ProjectActionProposal, kind: ProjectActionEvent.Kind,
                              previousStatus: String?) -> ProjectActionEvent {
        ProjectActionEvent(kind: kind, occurredAt: proposal.meetingDate,
                           meetingID: proposal.meetingID, meetingTitle: proposal.meetingTitle,
                           previousStatus: previousStatus, currentStatus: proposal.status,
                           owner: proposal.owner, due: proposal.due, evidence: proposal.evidence)
    }
}
