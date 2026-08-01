import Foundation

struct MeetingEmailDrafts: Codable, Sendable, Equatable {
    var chinese: String
    var hongKongTraditional: String
    var tone: String
    var audience: String
    var updatedAt: Date = Date()
}
