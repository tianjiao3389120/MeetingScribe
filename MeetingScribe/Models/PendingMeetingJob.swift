import Foundation

struct PendingMeetingJob: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let sourcePath: String
    let workspaceID: UUID?
    let tags: [String]
    let materialPaths: [String]

    init(id: UUID = UUID(), createdAt: Date = Date(), sourcePath: String,
         workspaceID: UUID?, tags: [String], materialPaths: [String]) {
        self.id = id; self.createdAt = createdAt; self.sourcePath = sourcePath
        self.workspaceID = workspaceID; self.tags = tags; self.materialPaths = materialPaths
    }
}
