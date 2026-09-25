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

    init(id: UUID = UUID(), name: String, kind: Kind, customerID: UUID? = nil,
         meetingTypes: [String]? = nil, context: String = "", contacts: [CustomerContact] = [],
         defaultTemplateID: String? = nil, defaultEmailTemplateID: String? = nil,
         createdAt: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind; self.customerID = customerID
        self.meetingTypes = meetingTypes; self.context = context; self.contacts = contacts
        self.defaultTemplateID = defaultTemplateID; self.defaultEmailTemplateID = defaultEmailTemplateID
        self.createdAt = createdAt
    }

    // Keep workspaces created by older releases readable after new fields are added.
    // Synthesized Decodable would fail the entire file when (for example) `contacts`
    // is absent, and callers would then silently fall back to an empty workspace list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        customerID = try container.decodeIfPresent(UUID.self, forKey: .customerID)
        meetingTypes = try container.decodeIfPresent([String].self, forKey: .meetingTypes)
        context = try container.decodeIfPresent(String.self, forKey: .context) ?? ""
        contacts = try container.decodeIfPresent([CustomerContact].self, forKey: .contacts) ?? []
        defaultTemplateID = try container.decodeIfPresent(String.self, forKey: .defaultTemplateID)
        defaultEmailTemplateID = try container.decodeIfPresent(String.self, forKey: .defaultEmailTemplateID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

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
