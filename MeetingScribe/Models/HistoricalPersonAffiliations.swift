import Foundation

/// Resolves speaker ownership without treating a person's name as a global
/// customer identifier. Company membership remains global, while customer
/// membership is scoped to the customer that owns the meeting.
struct HistoricalPersonAffiliations {
    private struct CustomerPersonKey: Hashable {
        let customerID: UUID
        let name: String
    }

    private var global: [String: SpeakerRole.Affiliation] = [:]
    private var customerScoped: [CustomerPersonKey: SpeakerRole.Affiliation] = [:]

    init(records: [MeetingRecord], workspaces: [MeetingWorkspace]) {
        let ordered = records.sorted {
            let lhs = Self.decisionDate(for: $0)
            let rhs = Self.decisionDate(for: $1)
            if lhs != rhs { return lhs > rhs }
            return $0.id.uuidString < $1.id.uuidString
        }

        for record in ordered {
            let customerID = Self.customerID(for: record, workspaces: workspaces)
            for (speaker, rawName) in record.speakerNames {
                let name = Self.normalizedName(rawName)
                guard !name.isEmpty,
                      let affiliation = record.speakerRoles?[speaker]?.affiliation,
                      affiliation != .unknown else { continue }

                if global[name] == nil { global[name] = affiliation }
                if let customerID {
                    let key = CustomerPersonKey(customerID: customerID, name: name)
                    if customerScoped[key] == nil { customerScoped[key] = affiliation }
                }
            }
        }
    }

    func globalAffiliation(for name: String) -> SpeakerRole.Affiliation? {
        global[Self.normalizedName(name)]
    }

    func affiliation(for name: String, customerID: UUID) -> SpeakerRole.Affiliation? {
        customerScoped[CustomerPersonKey(
            customerID: customerID,
            name: Self.normalizedName(name))]
    }

    static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func customerID(for record: MeetingRecord,
                           workspaces: [MeetingWorkspace]) -> UUID? {
        // Prefer the text classification for legacy records whose workspace ID
        // may still point at a customer or at an obsolete project.
        if let customerName = record.customerName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customerName.isEmpty,
           let customer = workspaces.first(where: {
               $0.isCustomer && $0.name.localizedCaseInsensitiveCompare(customerName) == .orderedSame
           }) {
            return customer.id
        }
        let project = record.workspaceID.flatMap { id in
            workspaces.first(where: { $0.id == id })
        } ?? workspaces.first(where: {
            !$0.isCustomer && $0.name.localizedCaseInsensitiveCompare(record.projectName ?? "") == .orderedSame
        })
        return project?.isCustomer == true ? project?.id : project?.customerID
    }

    private static func decisionDate(for record: MeetingRecord) -> Date {
        record.speakerMetadataUpdatedAt ?? record.generatedAt ?? record.createdAt
    }
}

enum CustomerContactDirectory {
    static func mergingHistoricalContacts(
        into source: [MeetingWorkspace],
        records: [MeetingRecord],
        affiliations: HistoricalPersonAffiliations
    ) -> [MeetingWorkspace] {
        var workspaces = source
        for record in records {
            guard let customerID = HistoricalPersonAffiliations.customerID(
                for: record, workspaces: workspaces),
                  let index = workspaces.firstIndex(where: { $0.id == customerID }) else { continue }
            for (speaker, name) in record.speakerNames {
                let key = HistoricalPersonAffiliations.normalizedName(name)
                guard !key.isEmpty,
                      affiliations.affiliation(for: name, customerID: customerID) == .customer else { continue }
                let role = record.speakerRoles?[speaker]?.meetingRole.label ?? "未确认"
                if let contact = workspaces[index].contacts.firstIndex(where: {
                    HistoricalPersonAffiliations.normalizedName($0.name) == key
                }) {
                    if workspaces[index].contacts[contact].role == "未确认" && role != "未确认" {
                        workspaces[index].contacts[contact].role = role
                    }
                } else {
                    workspaces[index].contacts.append(CustomerContact(name: name, role: role))
                }
            }
        }

        // Preserve manually maintained and unresolved contacts. Only an explicit
        // conflicting decision within this customer is allowed to remove one.
        for index in workspaces.indices where workspaces[index].isCustomer {
            let customerID = workspaces[index].id
            workspaces[index].contacts.removeAll {
                guard let affiliation = affiliations.affiliation(
                    for: $0.name, customerID: customerID) else { return false }
                return affiliation == .ours || affiliation == .thirdParty
            }
        }
        return workspaces
    }
}
