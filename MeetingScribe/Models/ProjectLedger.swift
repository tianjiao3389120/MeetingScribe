import Foundation

struct ProjectAction: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var workspaceID: UUID
    /// Stable link to the project issue this action helps resolve.
    /// Nil keeps independent actions and ledgers saved before this field existed compatible.
    var issueID: String? = nil
    var task: String
    var owner: String
    var status: String
    var due: String
    var createdAt: Date
    var updatedAt: Date
    var sourceMeetingID: UUID
    var events: [ProjectActionEvent]

    var isClosed: Bool { WorkspaceInsights.isClosed(status: status) }
    var isBlocked: Bool {
        let value = status.lowercased()
        return value.contains("阻塞") || value.contains("blocked")
            || value.contains("等待") || value.contains("受阻")
    }

    var dueDate: Date? { ProjectDateParser.parse(due, relativeTo: updatedAt) }
    var isOverdue: Bool {
        guard !isClosed, let dueDate else { return false }
        return dueDate < Calendar.current.startOfDay(for: Date())
    }
}

struct ProjectIssue: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var workspaceID: UUID
    var title: String
    var aliases: [String]
    /// Hidden retrieval profile generated from confirmed history.
    var searchTerms: [String]? = nil
    /// Terms that indicate a superficially similar but different issue.
    var negativeTerms: [String]? = nil
    var background: String
    var rootCause: String
    var solution: String
    var status: String
    var createdAt: Date
    var updatedAt: Date
    var sourceMeetingID: UUID
    var events: [ProjectIssueEvent]

    var isClosed: Bool { WorkspaceInsights.isClosed(status: status) }
}

struct ProjectIssueEvent: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case created, updated, closed }
    var id: UUID = UUID()
    var kind: Kind
    var occurredAt: Date
    var meetingID: UUID
    var meetingTitle: String
    var previousStatus: String?
    var currentStatus: String
    var title: String
    var background: String
    var rootCause: String
    var solution: String
    var progress: String
    var evidence: [String]
    var note: String? = nil
}

struct ProjectIssueProposal: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case create, update }
    enum Resolution: String, Codable, Sendable { case pending, accepted, ignored }
    var id: UUID = UUID()
    var workspaceID: UUID
    var meetingID: UUID
    var meetingTitle: String
    var meetingDate: Date
    var kind: Kind
    var targetIssueID: String?
    var title: String
    var background: String
    var rootCause: String
    var solution: String
    var progress: String
    var status: String
    var previousStatus: String?
    var evidence: [String]
    /// Latest profile proposed for this issue; nil keeps older ledgers compatible.
    var rollingSummary: String? = nil
    var proposedAliases: [String]? = nil
    var proposedSearchTerms: [String]? = nil
    var proposedNegativeTerms: [String]? = nil
    var resolution: Resolution = .pending
}

struct ProjectIssueAnalysis: Codable, Identifiable, Sendable, Equatable {
    struct TimelineItem: Codable, Identifiable, Sendable, Equatable {
        var id: UUID = UUID()
        var date: String
        var meetingTitle: String
        var change: String
    }

    var issueID: String
    var workspaceID: UUID
    var summary: String?
    var timeline: [TimelineItem]?
    var markdown: String?
    var generatedAt: Date
    var sourceEventIDs: [UUID]

    var id: String { issueID }

    func isStale(comparedWith issue: ProjectIssue) -> Bool {
        Set(sourceEventIDs) != Set(issue.events.map(\.id))
    }

    init(issueID: String, workspaceID: UUID, summary: String,
         timeline: [TimelineItem], generatedAt: Date, sourceEventIDs: [UUID]) {
        self.issueID = issueID
        self.workspaceID = workspaceID
        self.summary = summary
        self.timeline = timeline
        self.markdown = nil
        self.generatedAt = generatedAt
        self.sourceEventIDs = sourceEventIDs
    }
}

struct ProjectActionEvent: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case created, updated }
    var id: UUID = UUID()
    var kind: Kind
    var occurredAt: Date
    var meetingID: UUID
    var meetingTitle: String
    var issueID: String? = nil
    var previousStatus: String?
    var currentStatus: String
    var owner: String
    var due: String
    var evidence: [String]
}

struct ProjectActionProposal: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case create, update }
    enum Resolution: String, Codable, Sendable { case pending, accepted, ignored }
    var id: UUID = UUID()
    var workspaceID: UUID
    var meetingID: UUID
    var meetingTitle: String
    var meetingDate: Date
    var kind: Kind
    var targetActionID: String?
    var issueID: String? = nil
    var task: String
    var owner: String
    var status: String
    var due: String
    var previousStatus: String?
    var evidence: [String]
    var resolution: Resolution = .pending
}

struct ProjectLedger: Codable, Sendable, Equatable {
    var actions: [ProjectAction] = []
    var proposals: [ProjectActionProposal] = []
    var issues: [ProjectIssue] = []
    var issueProposals: [ProjectIssueProposal] = []
    var issueAnalyses: [ProjectIssueAnalysis] = []

    init(actions: [ProjectAction] = [], proposals: [ProjectActionProposal] = [],
         issues: [ProjectIssue] = [], issueProposals: [ProjectIssueProposal] = [],
         issueAnalyses: [ProjectIssueAnalysis] = []) {
        self.actions = actions; self.proposals = proposals
        self.issues = issues; self.issueProposals = issueProposals
        self.issueAnalyses = issueAnalyses
    }

    private enum CodingKeys: String, CodingKey {
        case actions, proposals, issues, issueProposals, issueAnalyses
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        actions = try values.decodeIfPresent([ProjectAction].self, forKey: .actions) ?? []
        proposals = try values.decodeIfPresent([ProjectActionProposal].self, forKey: .proposals) ?? []
        issues = try values.decodeIfPresent([ProjectIssue].self, forKey: .issues) ?? []
        issueProposals = try values.decodeIfPresent([ProjectIssueProposal].self,
                                                     forKey: .issueProposals) ?? []
        issueAnalyses = try values.decodeIfPresent([ProjectIssueAnalysis].self,
                                                   forKey: .issueAnalyses) ?? []
    }

    func actions(for workspaceID: UUID) -> [ProjectAction] {
        actions.filter { $0.workspaceID == workspaceID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func pendingProposals(for workspaceID: UUID) -> [ProjectActionProposal] {
        proposals.filter { $0.workspaceID == workspaceID && $0.resolution == .pending }
            .sorted { $0.meetingDate > $1.meetingDate }
    }

    func issues(for workspaceID: UUID) -> [ProjectIssue] {
        issues.filter { $0.workspaceID == workspaceID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func pendingIssueProposals(for workspaceID: UUID) -> [ProjectIssueProposal] {
        issueProposals.filter { $0.workspaceID == workspaceID && $0.resolution == .pending }
            .sorted { $0.meetingDate > $1.meetingDate }
    }

    func acceptedIssueProposals(for workspaceID: UUID) -> [ProjectIssueProposal] {
        issueProposals.filter { $0.workspaceID == workspaceID && $0.resolution == .accepted }
            .sorted { $0.meetingDate > $1.meetingDate }
    }

    func analysis(for issueID: String) -> ProjectIssueAnalysis? {
        issueAnalyses.first { $0.issueID == issueID }
    }
}

enum ProjectDateParser {
    static func parse(_ raw: String, relativeTo reference: Date) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd", "yyyy/M/d", "yyyy年M月d日"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        let pattern = #"(\d{1,2})月(\d{1,2})日"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let monthRange = Range(match.range(at: 1), in: value),
              let dayRange = Range(match.range(at: 2), in: value),
              let month = Int(value[monthRange]), let day = Int(value[dayRange]) else { return nil }
        var components = Calendar.current.dateComponents([.year], from: reference)
        components.month = month; components.day = day
        return Calendar.current.date(from: components)
    }
}
