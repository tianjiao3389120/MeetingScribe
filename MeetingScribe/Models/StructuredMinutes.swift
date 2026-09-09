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
        /// Stable internal identifier used to carry context across meetings.
        /// It is never rendered into customer-facing minutes.
        var trackingID: String? = nil
        var title: String
        var status: String
        /// Context that explains how the issue arose. Optional so minutes
        /// saved before this field was introduced continue to decode.
        var background: String? = nil
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
        var trackingID: String? = nil
        /// Optional link to the project issue this action helps resolve.
        var issueID: String? = nil
        var owner: String
        var task: String
        var status: String
        var due: String
        var evidence: [String]

        var isClosed: Bool {
            let value = status.lowercased()
            return value.contains("完成") || value.contains("关闭")
                || value.contains("closed") || value.contains("done")
        }
    }

    struct EvidenceItem: Codable, Sendable, Equatable {
        enum UncertaintyKind: String, Codable, Sendable {
            case speechRecognition = "speech_recognition"
            case unclearMeaning = "unclear_meaning"
        }

        var content: String
        var evidence: [String]
        /// Only used by uncertainties. Nil keeps older saved minutes compatible.
        var uncertaintyKind: UncertaintyKind? = nil
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
