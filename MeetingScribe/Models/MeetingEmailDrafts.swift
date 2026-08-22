import Foundation

struct MeetingEmailDrafts: Codable, Sendable, Equatable {
    var chinese: String
    var hongKongTraditional: String
    var tone: String
    var audience: String
    var templateID: String? = nil
    var hongKongUsage: GenerationUsage? = nil
    var updatedAt: Date = Date()
}
