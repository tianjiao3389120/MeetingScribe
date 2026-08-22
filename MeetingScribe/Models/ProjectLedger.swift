import Foundation

struct ProjectAction: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var workspaceID: UUID
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

struct ProjectActionEvent: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case created, updated }
    var id: UUID = UUID()
    var kind: Kind
    var occurredAt: Date
    var meetingID: UUID
    var meetingTitle: String
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

    func actions(for workspaceID: UUID) -> [ProjectAction] {
        actions.filter { $0.workspaceID == workspaceID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func pendingProposals(for workspaceID: UUID) -> [ProjectActionProposal] {
        proposals.filter { $0.workspaceID == workspaceID && $0.resolution == .pending }
            .sorted { $0.meetingDate > $1.meetingDate }
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
