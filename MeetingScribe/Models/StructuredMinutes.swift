import Foundation

/// Model-neutral meeting data. Markdown is a presentation generated locally,
/// while this value can later power history, search and cross-meeting diffs.
struct StructuredMinutes: Codable, Sendable, Equatable {
    var title: String
    var nature: String
    var duration: String
    var agenda: [String]
    var participantAssessment: [String]
    var issues: [Issue]
    var requirements: [Requirement]
    var actionItems: [ActionItem]
    var agreements: [EvidenceItem]
    var afterMeeting: [EvidenceItem]
    var uncertainties: [EvidenceItem]

    struct Issue: Codable, Sendable, Equatable {
        var title: String
        var status: String
        var rootCause: String
        var solution: String
        var progress: String
        var evidence: [String]
    }

    struct Requirement: Codable, Sendable, Equatable {
        var title: String
        var status: String
        var schedule: String
        var evidence: [String]
    }

    struct ActionItem: Codable, Sendable, Equatable {
        var owner: String
        var task: String
        var status: String
        var due: String
        var evidence: [String]
    }

    struct EvidenceItem: Codable, Sendable, Equatable {
        var content: String
        var evidence: [String]
    }

    /// Rejects an empty shell while tolerating naturally absent sections.
    var isMeaningful: Bool {
        !title.trimmed.isEmpty && (!agenda.isEmpty || !issues.isEmpty
            || !requirements.isEmpty || !actionItems.isEmpty || !agreements.isEmpty)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
