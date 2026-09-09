import Foundation

enum MeetingWorkspaceStore {
    private static let fallbackCustomerID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000101")!
    static let fileURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingScribe/workspaces.json")

    static func load(from url: URL = fileURL) throws -> [MeetingWorkspace] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([MeetingWorkspace].self, from: Data(contentsOf: url))
        let normalized = normalizeHierarchy(decoded)
        if normalized != decoded,
           url.standardizedFileURL == fileURL.standardizedFileURL {
            try save(normalized, to: url)
        }
        return normalized.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    static func save(_ values: [MeetingWorkspace], to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(values).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }

    static func resolve(id: UUID?, customerName: String?, projectName: String?,
                        from values: [MeetingWorkspace]? = nil) -> MeetingWorkspace? {
        let workspaces = values ?? ((try? load()) ?? [])
        if let id, let exact = workspaces.first(where: { $0.id == id }) { return exact }
        func normalized(_ value: String?) -> String {
            (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let customer = normalized(customerName), project = normalized(projectName)
        if !project.isEmpty {
            let customerIDs = Set(workspaces.filter {
                $0.isCustomer && normalized($0.name) == customer
            }.map(\.id))
            if let match = workspaces.first(where: {
                $0.isProject && normalized($0.name) == project
                    && (customerIDs.isEmpty || $0.customerID.map(customerIDs.contains) == true)
            }) { return match }
        }
        if !customer.isEmpty {
            return workspaces.first { $0.isCustomer && normalized($0.name) == customer }
        }
        return nil
    }

    static func normalizeHierarchy(_ values: [MeetingWorkspace]) -> [MeetingWorkspace] {
        var result = values
        let validCustomers = Set(result.filter(\.isCustomer).map(\.id))
        let needsFallback = result.contains { !$0.isCustomer && $0.customerID.map(validCustomers.contains) != true }
        var fallbackID: UUID?
        if needsFallback {
            if let existing = result.first(where: { $0.isCustomer && $0.name == "未归属客户" }) {
                fallbackID = existing.id
            } else {
                let fallback = MeetingWorkspace(
                    id: fallbackCustomerID, name: "未归属客户", kind: .customer)
                fallbackID = fallback.id
                result.append(fallback)
            }
        }
        for index in result.indices where !result[index].isCustomer {
            let legacyKind = result[index].kind
            result[index].kind = .project
            if result[index].customerID.map(validCustomers.contains) != true {
                result[index].customerID = fallbackID
            }
            if legacyKind == .recurring, result[index].configuredMeetingTypes.isEmpty {
                result[index].meetingTypes = ["固定会议"]
            }
        }
        return result
    }
}
