import Foundation

struct MeetingWorkspace: Codable, Identifiable, Sendable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case customer, project, task, recurring
        var id: String { rawValue }
        var label: String {
            switch self {
            case .customer: return "客户"
            case .project: return "普通项目"
            case .task: return "任务"
            case .recurring: return "固定会议"
            }
        }
    }

    var id: UUID = UUID()
    var name: String
    var kind: Kind
    /// Projects belong to a customer. Nil for customer nodes and legacy data.
    var customerID: UUID? = nil
    /// Controlled tags offered when preparing a meeting in this project.
    var meetingTypes: [String]? = nil
    var context: String = ""
    var contacts: [CustomerContact] = []
    /// Legacy per-workspace minutes template selection retained for Codable compatibility.
    /// New meeting preparation resolves the template explicitly for each meeting.
    var defaultTemplateID: String?
    var defaultEmailTemplateID: String?
    var createdAt: Date = Date()

    var isCustomer: Bool { kind == .customer }
    var isProject: Bool { !isCustomer }
    var configuredMeetingTypes: [String] { meetingTypes ?? [] }
}

struct CustomerContact: Codable, Identifiable, Sendable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var role: String = ""
    var organization: String = ""
    var note: String = ""
}

struct SupportingMaterial: Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case pdf, text, image }
    let id: UUID
    let sourceURL: URL
    let kind: Kind
    let extractedText: String
    let imageJPEG: Data?

    init(id: UUID = UUID(), sourceURL: URL, kind: Kind, extractedText: String,
         imageJPEG: Data? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.kind = kind
        self.extractedText = extractedText
        self.imageJPEG = imageJPEG
    }

    var name: String { sourceURL.lastPathComponent }
}

struct MaterialReference: Codable, Sendable, Equatable {
    let name: String
    let kind: SupportingMaterial.Kind
    let sourcePath: String
}
