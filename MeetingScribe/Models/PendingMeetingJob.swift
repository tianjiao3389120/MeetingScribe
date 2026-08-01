import Foundation

struct PendingMeetingJob: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let sourcePath: String
    let title: String?
    let meetingContext: String?
    let minutesTemplateID: String?
    let workspaceID: UUID?
    let tags: [String]
    let materialPaths: [String]

    init(id: UUID = UUID(), createdAt: Date = Date(), sourcePath: String,
         title: String = "", meetingContext: String = "", minutesTemplateID: String? = nil,
         workspaceID: UUID?, tags: [String], materialPaths: [String]) {
        self.id = id; self.createdAt = createdAt; self.sourcePath = sourcePath
        self.title = title; self.meetingContext = meetingContext
        self.minutesTemplateID = minutesTemplateID
        self.workspaceID = workspaceID; self.tags = tags; self.materialPaths = materialPaths
    }
}
