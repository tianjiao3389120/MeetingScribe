import Foundation

struct MeetingFeedback: Codable, Sendable, Equatable {
    enum Rating: String, Codable, CaseIterable, Identifiable {
        case accurate, needsImprovement
        var id: String { rawValue }
        var label: String { self == .accurate ? "基本准确" : "需要改进" }
    }

    enum Issue: String, Codable, CaseIterable, Identifiable {
        case missingDecision, inaccurateAction, speaker, terminology, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .missingDecision: return "遗漏决定"
            case .inaccurateAction: return "待办不准"
            case .speaker: return "说话人错误"
            case .terminology: return "术语错误"
            case .other: return "其他"
            }
        }
    }

    let meetingID: UUID
    var rating: Rating
    var issues: [Issue]
    var notes: String
    var updatedAt: Date = Date()
}

struct GlossaryCandidate: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let term: String
    let meetingID: UUID
    let sourceTitle: String
    let createdAt: Date

    init(id: UUID = UUID(), term: String, meetingID: UUID,
         sourceTitle: String, createdAt: Date = Date()) {
        self.id = id; self.term = term; self.meetingID = meetingID
        self.sourceTitle = sourceTitle; self.createdAt = createdAt
    }
}
