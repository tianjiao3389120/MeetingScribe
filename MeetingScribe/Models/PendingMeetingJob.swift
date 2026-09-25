import Foundation

struct PendingMeetingJob: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let sourcePath: String
    let title: String?
    let meetingContext: String?
    let minutesTemplateID: String?
    let recognitionScenario: RecognitionScenario?
    let workspaceID: UUID?
    let customerName: String?
    let projectName: String?
    let tags: [String]
    let materialPaths: [String]
    /// All selected input paths. Older media-only jobs decode this as nil.
    let sourcePaths: [String]?
    let meetingGroupID: UUID?

    init(id: UUID = UUID(), createdAt: Date = Date(), sourcePath: String,
         title: String = "", meetingContext: String = "", minutesTemplateID: String? = nil,
         recognitionScenario: RecognitionScenario? = nil,
         workspaceID: UUID?, customerName: String? = nil, projectName: String? = nil,
         tags: [String], materialPaths: [String], sourcePaths: [String]? = nil,
         meetingGroupID: UUID? = nil) {
        self.id = id; self.createdAt = createdAt; self.sourcePath = sourcePath
        self.title = title; self.meetingContext = meetingContext
        self.minutesTemplateID = minutesTemplateID
        self.recognitionScenario = recognitionScenario
        self.workspaceID = workspaceID
        self.customerName = customerName; self.projectName = projectName
        self.tags = tags; self.materialPaths = materialPaths
        self.sourcePaths = sourcePaths
        self.meetingGroupID = meetingGroupID
    }
}

struct PendingIssueReviewDraft: Codable, Sendable {
    let record: MeetingRecord
    let materialPaths: [String]
    let reasons: [String]
}
