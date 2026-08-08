import Foundation

struct MeetingRecord: Codable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    let id: UUID
    let schemaVersion: Int
    var createdAt: Date
    var title: String
    let sourcePath: String
    let duration: TimeInterval
    let backend: String
    let model: String
    var summaryMarkdown: String
    var structuredSummary: StructuredMinutes?
    let transcript: Transcript
    let speakerNames: [Int: String]
    let usedSummaryFallback: Bool
    /// Optional for backward compatibility with records created before spaces.
    var workspaceID: UUID?
    var tags: [String]?
    var materials: [MaterialReference]?
    var transcriptTranslations: [TranscriptTranslation]?
    var meetingContext: String?
    var minutesTemplateID: String?
    var emailDrafts: MeetingEmailDrafts?
    var isFavorite: Bool?
    var isArchived: Bool?
    var actionStatusSuggestions: [ActionStatusSuggestion]?
    var appliedActionSuggestionIDs: [UUID]?

    init(id: UUID = UUID(), createdAt: Date = Date(), title: String,
         sourcePath: String, duration: TimeInterval, backend: String,
         model: String, summaryMarkdown: String,
         structuredSummary: StructuredMinutes?, transcript: Transcript,
         speakerNames: [Int: String], usedSummaryFallback: Bool,
         workspaceID: UUID? = nil, tags: [String] = [],
         materials: [MaterialReference] = [],
         transcriptTranslations: [TranscriptTranslation] = []) {
        self.id = id
        schemaVersion = Self.currentSchemaVersion
        self.createdAt = createdAt
        self.title = title
        self.sourcePath = sourcePath
        self.duration = duration
        self.backend = backend
        self.model = model
        self.summaryMarkdown = summaryMarkdown
        self.structuredSummary = structuredSummary
        self.transcript = transcript
        self.speakerNames = speakerNames
        self.usedSummaryFallback = usedSummaryFallback
        self.workspaceID = workspaceID
        self.tags = tags
        self.materials = materials
        self.transcriptTranslations = transcriptTranslations
        self.meetingContext = nil
        self.minutesTemplateID = nil
        self.emailDrafts = nil
        self.isFavorite = nil
        self.isArchived = nil
        self.actionStatusSuggestions = nil
        self.appliedActionSuggestionIDs = nil
    }

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }

    var openActionCount: Int {
        structuredSummary?.actionItems.filter { !$0.isClosed }.count ?? 0
    }
}

struct ActionStatusSuggestion: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let targetMeetingID: UUID
    let targetActionID: String
    let task: String
    let previousStatus: String
    let proposedStatus: String
    let evidence: [String]

    init(id: UUID = UUID(), targetMeetingID: UUID, targetActionID: String,
         task: String, previousStatus: String, proposedStatus: String,
         evidence: [String]) {
        self.id = id; self.targetMeetingID = targetMeetingID
        self.targetActionID = targetActionID; self.task = task
        self.previousStatus = previousStatus; self.proposedStatus = proposedStatus
        self.evidence = evidence
    }
}

struct TranscriptTranslation: Codable, Sendable, Equatable {
    let segmentID: Int
    let text: String
}
