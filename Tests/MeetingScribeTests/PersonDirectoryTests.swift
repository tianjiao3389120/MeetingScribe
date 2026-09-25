import XCTest
@testable import MeetingScribe

final class PersonDirectoryTests: XCTestCase {
    func testCustomerAffiliationIsScopedAndManualContactsArePreserved() {
        let customerA = MeetingWorkspace(
            name: "客户甲", kind: .customer,
            contacts: [CustomerContact(name: "手工联系人"), CustomerContact(name: "Alex")])
        let customerB = MeetingWorkspace(
            name: "客户乙", kind: .customer,
            contacts: [CustomerContact(name: "Alex")])
        let projectA = MeetingWorkspace(name: "项目甲", kind: .project, customerID: customerA.id)
        let projectB = MeetingWorkspace(name: "项目乙", kind: .project, customerID: customerB.id)
        let workspaces = [customerA, customerB, projectA, projectB]

        let customerRecord = makeRecord(
            customer: customerA, project: projectA, name: "Alex", affiliation: .customer,
            decisionDate: Date(timeIntervalSince1970: 100))
        let companyRecord = makeRecord(
            customer: customerB, project: projectB, name: "Alex", affiliation: .ours,
            decisionDate: Date(timeIntervalSince1970: 200))
        let records = [customerRecord, companyRecord]
        let index = HistoricalPersonAffiliations(records: records, workspaces: workspaces)

        XCTAssertEqual(index.globalAffiliation(for: "Alex"), .ours)
        XCTAssertEqual(index.affiliation(for: "Alex", customerID: customerA.id), .customer)
        XCTAssertEqual(index.affiliation(for: "Alex", customerID: customerB.id), .ours)

        let merged = CustomerContactDirectory.mergingHistoricalContacts(
            into: workspaces, records: records, affiliations: index)
        let resultA = merged.first { $0.id == customerA.id }!
        let resultB = merged.first { $0.id == customerB.id }!
        XCTAssertEqual(Set(resultA.contacts.map(\.name)), ["手工联系人", "Alex"])
        XCTAssertTrue(resultB.contacts.isEmpty)
    }

    func testLaterSpeakerEditOverridesNewerMeetingDate() {
        let customer = MeetingWorkspace(name: "客户", kind: .customer)
        let project = MeetingWorkspace(name: "项目", kind: .project, customerID: customer.id)
        let newerMeeting = makeRecord(
            customer: customer, project: project, name: "Alex", affiliation: .customer,
            createdAt: Date(timeIntervalSince1970: 200),
            decisionDate: Date(timeIntervalSince1970: 200))
        let olderMeetingEditedLater = makeRecord(
            customer: customer, project: project, name: "Alex", affiliation: .ours,
            createdAt: Date(timeIntervalSince1970: 100),
            decisionDate: Date(timeIntervalSince1970: 300))

        let index = HistoricalPersonAffiliations(
            records: [newerMeeting, olderMeetingEditedLater], workspaces: [customer, project])
        XCTAssertEqual(index.globalAffiliation(for: "Alex"), .ours)
        XCTAssertEqual(index.affiliation(for: "Alex", customerID: customer.id), .ours)
    }

    func testVoiceProfileAffiliationSurvivesRoundTripAndLegacyJSON() throws {
        let profile = VoiceProfile(
            name: "Taylor", embedding: [1], affiliation: .ours, meetingRole: .engineer)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(VoiceProfile.self, from: data)
        XCTAssertEqual(decoded.affiliation, .ours)
        XCTAssertEqual(decoded.meetingRole, .engineer)

        let legacy = #"{"name":"旧人员","embedding":[1],"sampleCount":1,"updatedAt":0}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let legacyProfile = try decoder.decode(VoiceProfile.self, from: legacy)
        XCTAssertNil(legacyProfile.affiliation)
        XCTAssertEqual(legacyProfile.meetingRole, .unknown)
    }

    func testMatchedNameReceivesCustomerDirectoryRoleByDefault() {
        let customer = MeetingWorkspace(
            name: "星河银行", kind: .customer,
            contacts: [CustomerContact(name: "客户经理甲", role: "项目经理")])
        let project = MeetingWorkspace(
            name: "终端安全", kind: .project, customerID: customer.id)
        let roles = PersonRoleDirectory.defaults(
            names: [3: "客户经理甲"], workspace: project,
            workspaces: [customer, project], profiles: [])

        XCTAssertEqual(roles[3]?.affiliation, .customer)
        XCTAssertEqual(roles[3]?.meetingRole, .projectManager)
    }

    func testCompanyProfileRoleWinsOverSameNamedCustomerContact() {
        let customer = MeetingWorkspace(
            name: "客户", kind: .customer,
            contacts: [CustomerContact(name: "Taylor", role: "领导")])
        let project = MeetingWorkspace(name: "项目", kind: .project, customerID: customer.id)
        let profile = VoiceProfile(
            name: "Taylor", embedding: [1], affiliation: .ours, meetingRole: .engineer)
        let roles = PersonRoleDirectory.defaults(
            names: [1: "taylor"], workspace: project,
            workspaces: [customer, project], profiles: [profile])

        XCTAssertEqual(roles[1]?.affiliation, .ours)
        XCTAssertEqual(roles[1]?.meetingRole, .engineer)
    }

    func testVoiceProfileScopeIncludesCompanyAndWholeCustomerButNotOtherCustomers() {
        let customerA = MeetingWorkspace(name: "客户甲", kind: .customer)
        let customerB = MeetingWorkspace(name: "客户乙", kind: .customer)
        let projectA = MeetingWorkspace(name: "项目甲", kind: .project, customerID: customerA.id)
        let profiles = [
            VoiceProfile(name: "我司", embedding: [1], workspaceID: nil),
            VoiceProfile(name: "客户甲", embedding: [1], workspaceID: customerA.id),
            VoiceProfile(name: "项目甲", embedding: [1], workspaceID: projectA.id),
            VoiceProfile(name: "客户乙", embedding: [1], workspaceID: customerB.id)
        ]

        let scoped = VoiceProfileStore.scopedProfiles(
            profiles, workspaceID: projectA.id, workspaces: [customerA, customerB, projectA])
        XCTAssertEqual(Set(scoped.map(\.name)), ["我司", "客户甲", "项目甲"])
    }

    func testLegacyUnscopedCustomerVoiceOnlyMatchesItsHistoricalCustomer() {
        let customerA = MeetingWorkspace(name: "客户甲", kind: .customer)
        let customerB = MeetingWorkspace(name: "客户乙", kind: .customer)
        let projectA = MeetingWorkspace(name: "项目甲", kind: .project, customerID: customerA.id)
        let projectB = MeetingWorkspace(name: "项目乙", kind: .project, customerID: customerB.id)
        let record = makeRecord(
            customer: customerA, project: projectA, name: "Alex", affiliation: .customer,
            decisionDate: Date(timeIntervalSince1970: 100))
        let workspaces = [customerA, customerB, projectA, projectB]
        let index = HistoricalPersonAffiliations(records: [record], workspaces: workspaces)
        let legacy = VoiceProfile(name: "Alex", embedding: [1], workspaceID: nil)

        XCTAssertEqual(VoiceProfileStore.scopedProfiles(
            [legacy], workspaceID: projectA.id, workspaces: workspaces,
            affiliations: index).count, 1)
        XCTAssertTrue(VoiceProfileStore.scopedProfiles(
            [legacy], workspaceID: projectB.id, workspaces: workspaces,
            affiliations: index).isEmpty)
    }

    func testLegacyCompanyVoiceRemainsGlobalFromHistoricalAffiliation() {
        let customerA = MeetingWorkspace(name: "客户甲", kind: .customer)
        let customerB = MeetingWorkspace(name: "客户乙", kind: .customer)
        let projectA = MeetingWorkspace(name: "项目甲", kind: .project, customerID: customerA.id)
        let projectB = MeetingWorkspace(name: "项目乙", kind: .project, customerID: customerB.id)
        let record = makeRecord(
            customer: customerA, project: projectA, name: "Taylor", affiliation: .ours,
            decisionDate: Date(timeIntervalSince1970: 100))
        let workspaces = [customerA, customerB, projectA, projectB]
        let index = HistoricalPersonAffiliations(records: [record], workspaces: workspaces)
        let legacy = VoiceProfile(name: "Taylor", embedding: [1], workspaceID: nil)

        XCTAssertEqual(VoiceProfileStore.scopedProfiles(
            [legacy], workspaceID: projectB.id, workspaces: workspaces,
            affiliations: index).count, 1)
    }

    func testVoiceProfileIdentityAllowsSameNameInDifferentCustomerScopes() {
        let first = UUID(), second = UUID()
        XCTAssertNotEqual(
            VoiceProfileStore.identityKey(name: " Alex ", workspaceID: first),
            VoiceProfileStore.identityKey(name: "alex", workspaceID: second))
        XCTAssertEqual(
            VoiceProfileStore.identityKey(name: " Alex ", workspaceID: first),
            VoiceProfileStore.identityKey(name: "alex", workspaceID: first))
    }

    func testProductionSeedMaterializesLegacyCustomerAndCompanyScopes() {
        let customer = MeetingWorkspace(
            name: "客户甲", kind: .customer,
            contacts: [CustomerContact(name: "Alex")])
        let project = MeetingWorkspace(name: "项目甲", kind: .project, customerID: customer.id)
        let customerRecord = makeRecord(
            customer: customer, project: project, name: "Alex", affiliation: .customer,
            decisionDate: Date(timeIntervalSince1970: 100))
        let companyRecord = makeRecord(
            customer: customer, project: project, name: "Taylor", affiliation: .ours,
            decisionDate: Date(timeIntervalSince1970: 100))
        let index = HistoricalPersonAffiliations(
            records: [customerRecord, companyRecord], workspaces: [customer, project])

        let customerProfile = ProductionEnvironmentSeeder.resolvedLegacyProfile(
            VoiceProfile(name: "Alex", embedding: [1]),
            affiliations: index, workspaces: [customer, project])
        let companyProfile = ProductionEnvironmentSeeder.resolvedLegacyProfile(
            VoiceProfile(name: "Taylor", embedding: [1]),
            affiliations: index, workspaces: [customer, project])

        XCTAssertEqual(customerProfile.workspaceID, customer.id)
        XCTAssertEqual(customerProfile.affiliation, .customer)
        XCTAssertNil(companyProfile.workspaceID)
        XCTAssertEqual(companyProfile.affiliation, .ours)
    }

    private func makeRecord(
        customer: MeetingWorkspace,
        project: MeetingWorkspace,
        name: String,
        affiliation: SpeakerRole.Affiliation,
        createdAt: Date = Date(timeIntervalSince1970: 50),
        decisionDate: Date
    ) -> MeetingRecord {
        var record = MeetingRecord(
            createdAt: createdAt, title: "测试会议", sourcePath: "/tmp/test.mov",
            duration: 1, backend: "test", model: "test", summaryMarkdown: "",
            structuredSummary: nil, transcript: Transcript(segments: []),
            speakerNames: [0: name], usedSummaryFallback: false,
            speakerRoles: [0: SpeakerRole(affiliation: affiliation)],
            workspaceID: project.id, customerName: customer.name, projectName: project.name)
        record.speakerMetadataUpdatedAt = decisionDate
        return record
    }
}
