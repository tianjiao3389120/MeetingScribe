import Foundation

struct MeetingRecord: Codable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let createdAt: Date
    let title: String
    let sourcePath: String
    let duration: TimeInterval
    let backend: String
    let model: String
    let summaryMarkdown: String
    let structuredSummary: StructuredMinutes?
    let transcript: Transcript
    let speakerNames: [Int: String]
    let usedSummaryFallback: Bool

    init(id: UUID = UUID(), createdAt: Date = Date(), title: String,
         sourcePath: String, duration: TimeInterval, backend: String,
         model: String, summaryMarkdown: String,
         structuredSummary: StructuredMinutes?, transcript: Transcript,
         speakerNames: [Int: String], usedSummaryFallback: Bool) {
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
    }

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
}
