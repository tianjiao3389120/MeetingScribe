import Foundation

/// Creates a clean production library while carrying over only reusable,
/// explicitly learned knowledge. Meeting history, caches, issues, usage and
/// debug artifacts never cross the boundary.
enum ProductionEnvironmentSeeder {
    struct Receipt: Codable, Sendable {
        let createdAt: Date
        let workspaceCount: Int
        let voiceProfileCount: Int
        let recognitionMemoryCount: Int
    }

    private static var receiptURL: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("production-seed.json")
    }

    @discardableResult
    static func seedIfNeeded() throws -> Receipt? {
        guard AppEnvironment.isProduction,
              !FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }

        let source = AppEnvironment.testSupportDirectory
        let destination = AppEnvironment.supportDirectory
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: destination.path)

        let sourceWorkspaces = source.appendingPathComponent("workspaces.json")
        let workspaces = (try? MeetingWorkspaceStore.load(from: sourceWorkspaces)) ?? []
        if !workspaces.isEmpty {
            try MeetingWorkspaceStore.save(
                workspaces, to: destination.appendingPathComponent("workspaces.json"))
        }

        let records = (try? MeetingHistoryStore.loadAll(
            root: source.appendingPathComponent("Meetings", isDirectory: true))) ?? []
        let affiliations = HistoricalPersonAffiliations(records: records, workspaces: workspaces)
        let sourceProfilesURL = source.appendingPathComponent("voice-profiles.json")
        var profiles = (try? JSONDecoder().decode(
            [VoiceProfile].self, from: Data(contentsOf: sourceProfilesURL))) ?? []
        profiles = profiles.map {
            resolvedLegacyProfile(
                $0, affiliations: affiliations, workspaces: workspaces)
        }
        if !profiles.isEmpty { try VoiceProfileStore.save(profiles) }

        let sourceClips = source.appendingPathComponent("voice-profile-clips", isDirectory: true)
        let destinationClips = destination.appendingPathComponent(
            "voice-profile-clips", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceClips.path),
           !FileManager.default.fileExists(atPath: destinationClips.path) {
            try FileManager.default.copyItem(at: sourceClips, to: destinationClips)
        }

        let sourceMemory = source.appendingPathComponent("RecognitionMemory/entries.json")
        let memories = RecognitionMemoryStore.load(from: sourceMemory)
        if !memories.isEmpty {
            try RecognitionMemoryStore.save(memories)
        }

        let receipt = Receipt(
            createdAt: Date(), workspaceCount: workspaces.count,
            voiceProfileCount: profiles.count, recognitionMemoryCount: memories.count)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: receiptURL.path)
        return receipt
    }

    static func loadReceipt() -> Receipt? {
        guard let data = try? Data(contentsOf: receiptURL) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Receipt.self, from: data)
    }

    static func resolvedLegacyProfile(
        _ source: VoiceProfile,
        affiliations: HistoricalPersonAffiliations,
        workspaces: [MeetingWorkspace]
    ) -> VoiceProfile {
        var profile = source
        guard profile.workspaceID == nil else { return profile }

        let historical = affiliations.globalAffiliation(for: profile.name)
        if profile.affiliation == .ours || historical == .ours {
            profile.affiliation = .ours
            return profile
        }

        let desiredAffiliation = profile.affiliation ?? historical
        var customerIDs = Set<UUID>()
        if let desiredAffiliation, desiredAffiliation != .unknown {
            customerIDs.formUnion(affiliations.customerIDs(
                for: profile.name, affiliation: desiredAffiliation))
        }
        let normalized = HistoricalPersonAffiliations.normalizedName(profile.name)
        customerIDs.formUnion(workspaces.filter { workspace in
            workspace.isCustomer && workspace.contacts.contains {
                HistoricalPersonAffiliations.normalizedName($0.name) == normalized
            }
        }.map(\.id))
        if customerIDs.isEmpty {
            customerIDs = affiliations.customerIDs(for: profile.name)
        }
        if customerIDs.count == 1, let customerID = customerIDs.first {
            profile.workspaceID = customerID
            profile.affiliation = desiredAffiliation == .thirdParty ? .thirdParty : .customer
        }
        return profile
    }
}
