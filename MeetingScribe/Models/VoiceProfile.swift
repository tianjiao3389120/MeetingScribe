import Foundation

/// A person's enrolled voiceprint.
struct VoiceProfile: Codable, Identifiable, Sendable {
    static let maximumRepresentativeSamples = 8

    var id: UUID = UUID()
    var name: String
    var workspaceID: UUID? = nil
    /// Persisted directory ownership keeps a confirmed company profile stable
    /// when its display name is edited and no history record uses the new name yet.
    var affiliation: SpeakerRole.Affiliation? = nil
    /// Default organizational role. A meeting can override it without changing
    /// the directory; automatic recognition uses it only as a prefill.
    var meetingRole: SpeakerRole.MeetingRole = .unknown
    /// Unit-length mean of the samples enrolled so far.
    var embedding: [Float]
    /// A bounded set that preserves different microphones and acoustic
    /// conditions instead of collapsing every confirmation into one centroid.
    var representativeEmbeddings: [[Float]] = []
    var sampleCount: Int = 1
    /// Samples that were explicitly labelled as this person but rejected as
    /// acoustic outliers, preventing one bad confirmation from poisoning the profile.
    var quarantinedSampleCount: Int = 0
    var lastQuarantinedAt: Date? = nil
    /// One manually confirmed, high-quality outlier is retained temporarily.
    /// A second consistent outlier promotes both as a new acoustic environment.
    var pendingEnvironmentEmbedding: [Float]? = nil
    var pendingEnvironmentCount: Int = 0
    var updatedAt: Date = Date()
    var note: String = ""
    /// Filename of a short, local reference clip used for manual identification.
    var referenceClip: String? = nil

    init(id: UUID = UUID(), name: String, embedding: [Float], sampleCount: Int = 1,
         workspaceID: UUID? = nil,
         affiliation: SpeakerRole.Affiliation? = nil,
         meetingRole: SpeakerRole.MeetingRole = .unknown,
         updatedAt: Date = Date(), note: String = "", referenceClip: String? = nil,
         quarantinedSampleCount: Int = 0, lastQuarantinedAt: Date? = nil,
         pendingEnvironmentEmbedding: [Float]? = nil, pendingEnvironmentCount: Int = 0,
         representativeEmbeddings: [[Float]]? = nil) {
        self.id = id
        self.name = name
        self.workspaceID = workspaceID
        self.affiliation = affiliation
        self.meetingRole = meetingRole
        self.embedding = embedding
        self.representativeEmbeddings = representativeEmbeddings ?? (embedding.isEmpty ? [] : [embedding])
        self.sampleCount = sampleCount
        self.quarantinedSampleCount = quarantinedSampleCount
        self.lastQuarantinedAt = lastQuarantinedAt
        self.pendingEnvironmentEmbedding = pendingEnvironmentEmbedding
        self.pendingEnvironmentCount = pendingEnvironmentCount
        self.updatedAt = updatedAt
        self.note = note
        self.referenceClip = referenceClip
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, workspaceID, affiliation, meetingRole, embedding, representativeEmbeddings, sampleCount,
             quarantinedSampleCount, lastQuarantinedAt, updatedAt, note, referenceClip
        case pendingEnvironmentEmbedding, pendingEnvironmentCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        workspaceID = try values.decodeIfPresent(UUID.self, forKey: .workspaceID)
        affiliation = try values.decodeIfPresent(SpeakerRole.Affiliation.self, forKey: .affiliation)
        meetingRole = try values.decodeIfPresent(
            SpeakerRole.MeetingRole.self, forKey: .meetingRole) ?? .unknown
        embedding = try values.decode([Float].self, forKey: .embedding)
        representativeEmbeddings = try values.decodeIfPresent(
            [[Float]].self, forKey: .representativeEmbeddings) ?? (embedding.isEmpty ? [] : [embedding])
        sampleCount = try values.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 1
        quarantinedSampleCount = try values.decodeIfPresent(
            Int.self, forKey: .quarantinedSampleCount) ?? 0
        lastQuarantinedAt = try values.decodeIfPresent(Date.self, forKey: .lastQuarantinedAt)
        pendingEnvironmentEmbedding = try values.decodeIfPresent(
            [Float].self, forKey: .pendingEnvironmentEmbedding)
        pendingEnvironmentCount = try values.decodeIfPresent(
            Int.self, forKey: .pendingEnvironmentCount) ?? 0
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        referenceClip = try values.decodeIfPresent(String.self, forKey: .referenceClip)
    }

    /// Folds a new sample into the running mean, so a person's profile improves
    /// as they appear in more meetings rather than being replaced by the latest
    /// (possibly worse) recording.
    mutating func merge(_ sample: [Float]) {
        guard sample.count == embedding.count else { return }
        retainRepresentative(sample)
        let weight = Float(sampleCount)
        var combined = zip(embedding, sample).map { ($0 * weight + $1) / (weight + 1) }
        let norm = sqrt(combined.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { combined = combined.map { $0 / norm } }
        embedding = combined
        sampleCount += 1
        updatedAt = Date()
    }

    mutating func quarantineSample(_ sample: [Float]? = nil,
                                   allowEnvironmentAdaptation: Bool = false) {
        quarantinedSampleCount += 1
        lastQuarantinedAt = Date()
        guard allowEnvironmentAdaptation, let sample,
              sample.count == embedding.count, !sample.isEmpty else { return }
        if let pending = pendingEnvironmentEmbedding,
           pending.count == sample.count,
           VoiceProfileStore.similarity(pending, sample)
                >= VoiceProfileStore.environmentAdaptationThreshold {
            pendingEnvironmentEmbedding = nil
            pendingEnvironmentCount = 0
            // Two independent manual confirmations are enough to represent a
            // changed microphone without letting one outlier move the profile.
            merge(pending)
            merge(sample)
        } else {
            pendingEnvironmentEmbedding = sample
            pendingEnvironmentCount = 1
        }
    }

    private mutating func retainRepresentative(_ sample: [Float]) {
        if representativeEmbeddings.isEmpty, !embedding.isEmpty {
            representativeEmbeddings = [embedding]
        }
        guard !sample.isEmpty else { return }
        let closest = representativeEmbeddings.map { VoiceProfileStore.similarity($0, sample) }.max() ?? -1
        guard closest < 0.985 else { return }
        if representativeEmbeddings.count < Self.maximumRepresentativeSamples {
            representativeEmbeddings.append(sample)
            return
        }

        // Replace one member of the most redundant pair only when the new
        // sample adds more acoustic coverage than that pair provides.
        var redundantPair: (first: Int, second: Int, similarity: Float)?
        for first in representativeEmbeddings.indices {
            for second in representativeEmbeddings.indices where second > first {
                let score = VoiceProfileStore.similarity(
                    representativeEmbeddings[first], representativeEmbeddings[second])
                if redundantPair == nil || score > redundantPair!.similarity {
                    redundantPair = (first, second, score)
                }
            }
        }
        if let pair = redundantPair, closest < pair.similarity {
            representativeEmbeddings[pair.second] = sample
        }
    }
}

/// Enrolled voiceprints, persisted as one JSON file.
enum VoiceProfileStore {

    struct MatchReport {
        let names: [Int: String]
        let suggestions: [Int: VoiceMatchSuggestion]
        let logDescription: String
    }

    struct EnrollmentSample {
        let name: String
        let embedding: [Float]
        let note: String
        let referenceClipURL: URL?
        let workspaceID: UUID?
        let affiliation: SpeakerRole.Affiliation?
        let meetingRole: SpeakerRole.MeetingRole
        let quality: Float?

        init(name: String, embedding: [Float], note: String, referenceClipURL: URL?,
             workspaceID: UUID?, affiliation: SpeakerRole.Affiliation?, quality: Float? = nil) {
            self.name = name; self.embedding = embedding; self.note = note
            self.referenceClipURL = referenceClipURL; self.workspaceID = workspaceID
            self.affiliation = affiliation; self.quality = quality
            self.meetingRole = .unknown
        }

        init(name: String, embedding: [Float], note: String, referenceClipURL: URL?,
             workspaceID: UUID?, affiliation: SpeakerRole.Affiliation?,
             meetingRole: SpeakerRole.MeetingRole, quality: Float? = nil) {
            self.name = name; self.embedding = embedding; self.note = note
            self.referenceClipURL = referenceClipURL; self.workspaceID = workspaceID
            self.affiliation = affiliation; self.meetingRole = meetingRole
            self.quality = quality
        }
    }

    private static let fileURL: URL = {
        Diarizer.supportDirectory.appendingPathComponent("voice-profiles.json")
    }()
    private static let clipsDirectory = Diarizer.supportDirectory
        .appendingPathComponent("voice-profile-clips", isDirectory: true)

    static func referenceClipURL(for profile: VoiceProfile) -> URL? {
        guard let filename = profile.referenceClip, !filename.isEmpty else { return nil }
        let url = clipsDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Cosine similarity above which a cluster is considered the same person.
    ///
    /// Conference audio is compressed and the same speaker's embeddings drift,
    /// so this sits deliberately low; getting a name wrong is worse than
    /// leaving it anonymous, but too high a bar makes enrolment pointless.
    /// Callers also require a margin over the runner-up before accepting.
    static let matchThreshold: Float = 0.55
    static let ambiguityMargin: Float = 0.06
    static let automaticMatchThreshold: Float = 0.62
    static let automaticAmbiguityMargin: Float = 0.08
    static let minimumEmbeddingQuality: Float = 0.42
    static let minimumAutomaticSampleQuality: Float = 0.65
    static let minimumAutomaticSampleDuration: TimeInterval = 4
    static let enrollmentOutlierThreshold: Float = 0.40
    static let environmentAdaptationThreshold: Float = 0.75

    static func shouldQuarantineEnrollment(targetScore: Float, strongestOther: Float,
                                           quality: Float?) -> Bool {
        if let quality, quality < minimumEmbeddingQuality { return true }
        return targetScore < enrollmentOutlierThreshold
            || (strongestOther >= matchThreshold
                && strongestOther - targetScore >= automaticAmbiguityMargin)
    }

    enum Failure: LocalizedError {
        case invalidName
        case duplicateName(String)

        var errorDescription: String? {
            switch self {
            case .invalidName: return "姓名不能为空。"
            case .duplicateName(let name): return "姓名“\(name)”重复，请合并或使用不同姓名。"
            }
        }
    }

    /// Best-effort read for automatic matching. A damaged profile store must
    /// not make an otherwise valid meeting fail to process.
    static func load() -> [VoiceProfile] {
        (try? loadChecked()) ?? []
    }

    /// Checked read for management UI, where storage errors must be visible.
    static func loadChecked() throws -> [VoiceProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let profiles = try JSONDecoder().decode([VoiceProfile].self, from: data)
        return profiles.sorted { $0.name < $1.name }
    }

    static func save(_ profiles: [VoiceProfile]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: fileURL, options: .atomic)
        // Voiceprints are biometric data: only the current user may read them.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path)
    }

    /// Adds a sample under `name`, merging into an existing profile if the name
    /// already exists.
    static func enroll(name: String, embedding: [Float], note: String = "") throws {
        try enroll(samples: [(name: name, embedding: embedding, note: note)])
    }

    /// Enrols a meeting's confirmed speakers in one atomic file update. Either
    /// every name is persisted or none are, avoiding a half-saved meeting.
    static func enroll(samples: [(name: String, embedding: [Float], note: String,
                                  referenceClipURL: URL?)]) throws {
        try enroll(samples: samples, workspaceID: nil, affiliation: nil)
    }

    static func enroll(samples: [(name: String, embedding: [Float], note: String,
                                  referenceClipURL: URL?)], workspaceID: UUID?,
                       affiliation: SpeakerRole.Affiliation? = nil) throws {
        try enroll(samples.map {
            EnrollmentSample(name: $0.name, embedding: $0.embedding, note: $0.note,
                             referenceClipURL: $0.referenceClipURL,
                             workspaceID: workspaceID, affiliation: affiliation)
        })
    }

    static func enroll(_ samples: [EnrollmentSample]) throws {
        var profiles = try loadChecked()
        var newlyCopied: [URL] = []
        var supersededClips: [URL] = []
        var committed = false
        defer {
            if !committed { newlyCopied.forEach { try? FileManager.default.removeItem(at: $0) } }
        }
        for sample in samples {
            let trimmed = sample.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Failure.invalidName }
            guard !sample.embedding.isEmpty else { continue }

            let targetIndex = profiles.firstIndex(where: {
                $0.name == trimmed && $0.workspaceID == sample.workspaceID
            })
            if let quality = sample.quality, quality < minimumEmbeddingQuality {
                if let targetIndex { profiles[targetIndex].quarantineSample() }
                continue
            }

            if let index = targetIndex {
                let targetScore = matchScore(sample.embedding, profile: profiles[index])
                let targetName = HistoricalPersonAffiliations.normalizedName(profiles[index].name)
                let strongestOther = profiles.enumerated().filter { candidate in
                    candidate.offset != index
                        && HistoricalPersonAffiliations.normalizedName(candidate.element.name) != targetName
                        && (candidate.element.workspaceID == nil
                            || candidate.element.workspaceID == sample.workspaceID)
                }.map { matchScore(sample.embedding, profile: $0.element) }.max() ?? -1
                if shouldQuarantineEnrollment(
                    targetScore: targetScore, strongestOther: strongestOther,
                    quality: sample.quality) {
                    let mayBeNewEnvironment = targetScore < enrollmentOutlierThreshold
                        && strongestOther < matchThreshold
                        && (sample.quality ?? 1) >= minimumEmbeddingQuality
                    profiles[index].quarantineSample(
                        sample.embedding,
                        allowEnvironmentAdaptation: mayBeNewEnvironment)
                    continue
                }
                profiles[index].merge(sample.embedding)
                if let affiliation = sample.affiliation { profiles[index].affiliation = affiliation }
                if sample.meetingRole != .unknown { profiles[index].meetingRole = sample.meetingRole }
                if !sample.note.isEmpty { profiles[index].note = sample.note }
                if let source = sample.referenceClipURL {
                    let oldClip = referenceClipURL(for: profiles[index])
                    let stored = try storeReferenceClip(from: source)
                    newlyCopied.append(stored)
                    profiles[index].referenceClip = stored.lastPathComponent
                    if let oldClip { supersededClips.append(oldClip) }
                }
            } else {
                var profile = VoiceProfile(name: trimmed, embedding: sample.embedding,
                                           workspaceID: sample.workspaceID,
                                           affiliation: sample.affiliation,
                                           meetingRole: sample.meetingRole,
                                           note: sample.note)
                if let source = sample.referenceClipURL {
                    let stored = try storeReferenceClip(from: source)
                    newlyCopied.append(stored)
                    profile.referenceClip = stored.lastPathComponent
                }
                profiles.append(profile)
            }
        }
        try save(profiles)
        committed = true
        supersededClips.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    static func enroll(samples: [(name: String, embedding: [Float], note: String)]) throws {
        try enroll(samples: samples.map { ($0.name, $0.embedding, $0.note, nil) })
    }

    private static func storeReferenceClip(from source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        let destination = clipsDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                                              ofItemAtPath: destination.path)
        return destination
    }

    static func replace(_ profiles: [VoiceProfile]) throws {
        let previous = try loadChecked()
        var seen = Set<String>()
        var normalized = profiles
        for index in normalized.indices {
            let name = normalized[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw Failure.invalidName }
            // The same display name may legitimately exist in two customer
            // scopes. Only duplicates inside the same biometric scope conflict.
            let key = identityKey(name: name, workspaceID: normalized[index].workspaceID)
            guard seen.insert(key).inserted else { throw Failure.duplicateName(name) }
            normalized[index].name = name
            normalized[index].updatedAt = Date()
        }
        try save(normalized)
        let retainedIDs = Set(normalized.map(\.id))
        for profile in previous where !retainedIDs.contains(profile.id) {
            if let clip = referenceClipURL(for: profile) {
                try? FileManager.default.removeItem(at: clip)
            }
        }
    }

    static func identityKey(name: String, workspaceID: UUID?) -> String {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        return "\(workspaceID?.uuidString ?? "global")|\(normalizedName)"
    }

    static func remove(id: UUID) throws {
        let profiles = try loadChecked()
        if let profile = profiles.first(where: { $0.id == id }), let clip = referenceClipURL(for: profile) {
            try? FileManager.default.removeItem(at: clip)
        }
        try save(profiles.filter { $0.id != id })
    }

    static func removeAll() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try? FileManager.default.removeItem(at: clipsDirectory)
        try? VoiceRecognitionMetricsStore.removeAll()
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func matchScore(_ embedding: [Float], profile: VoiceProfile) -> Float {
        let centroid = similarity(embedding, profile.embedding)
        let representatives = profile.representativeEmbeddings.filter {
            $0.count == embedding.count && !$0.isEmpty
        }
        guard let best = representatives.map({ similarity(embedding, $0) }).max() else {
            return centroid
        }
        // A representative handles environment changes; the centroid keeps a
        // single noisy or incorrectly labelled sample from dominating.
        return best * 0.7 + centroid * 0.3
    }

    /// Best enrolled match per cluster.
    ///
    /// Rejects a match that is barely ahead of the next candidate: two people
    /// with similar voices should both stay anonymous rather than one being
    /// confidently mislabelled as the other. Multiple clusters may resolve to
    /// the same profile: diarization can split one person when microphone
    /// distance, noise or compression changes during a meeting.
    static func match(embeddings: [String: [Float]], workspaceID: UUID? = nil) -> [Int: String] {
        matchReport(embeddings: embeddings, workspaceID: workspaceID).names
    }

    static func matchReport(embeddings: [String: [Float]],
                            qualities: [String: VoiceEmbeddingQuality] = [:],
                            workspaceID: UUID? = nil) -> MatchReport {
        let workspaces = (try? MeetingWorkspaceStore.load()) ?? []
        let records = (try? MeetingHistoryStore.loadAll()) ?? []
        let affiliations = HistoricalPersonAffiliations(records: records, workspaces: workspaces)
        let profiles = scopedProfiles(
            load(), workspaceID: workspaceID, workspaces: workspaces,
            affiliations: affiliations)
        return matchReport(embeddings: embeddings, qualities: qualities, profiles: profiles)
    }

    static func scopedProfiles(_ profiles: [VoiceProfile], workspaceID: UUID?,
                               workspaces: [MeetingWorkspace],
                               affiliations: HistoricalPersonAffiliations? = nil) -> [VoiceProfile] {
        var permittedScopes = Set<UUID>()
        var currentCustomerID: UUID?
        if let workspaceID {
            permittedScopes.insert(workspaceID)
            if let workspace = workspaces.first(where: { $0.id == workspaceID }),
               let customerID = workspace.isCustomer ? workspace.id : workspace.customerID {
                permittedScopes.insert(customerID)
                currentCustomerID = customerID
            }
        }
        return profiles.filter { profile in
            if let scope = profile.workspaceID { return permittedScopes.contains(scope) }
            // New global profiles are explicitly company-owned. Legacy files
            // had neither affiliation nor scope, so resolve them from meeting
            // history instead of exposing every customer voice to every project.
            if profile.affiliation == .ours { return true }
            guard let affiliations else { return true }
            if affiliations.globalAffiliation(for: profile.name) == .ours { return true }
            guard let currentCustomerID else { return false }
            if let scoped = affiliations.affiliation(
                for: profile.name, customerID: currentCustomerID) {
                return scoped == .customer || scoped == .thirdParty
            }
            let contactMatch = workspaces.first(where: { $0.id == currentCustomerID })?
                .contacts.contains {
                    HistoricalPersonAffiliations.normalizedName($0.name)
                        == HistoricalPersonAffiliations.normalizedName(profile.name)
                } == true
            let mentionedCustomers = affiliations.customerIDs(for: profile.name)
            return contactMatch
                || (mentionedCustomers.count == 1 && mentionedCustomers.contains(currentCustomerID))
        }
    }

    static func match(embeddings: [String: [Float]], profiles: [VoiceProfile]) -> [Int: String] {
        matchReport(embeddings: embeddings, profiles: profiles).names
    }

    static func matchReport(embeddings: [String: [Float]],
                            qualities: [String: VoiceEmbeddingQuality] = [:],
                            profiles: [VoiceProfile]) -> MatchReport {
        guard !profiles.isEmpty else {
            return MatchReport(names: [:], suggestions: [:],
                               logDescription: "没有当前范围内可参与匹配的历史声纹。")
        }

        var names: [Int: String] = [:]
        var suggestions: [Int: VoiceMatchSuggestion] = [:]
        var lines: [String] = []
        let keys = Set(embeddings.keys).union(qualities.keys).sorted()
        for key in keys {
            guard let speaker = Int(key) else { continue }
            let qualityRecord = qualities[key]
            let quality = qualityRecord?.score
            let qualityText = qualityRecord.map {
                String(format: "%.2f（有效 %.1f 秒 / %d 段，干净片段 %@）",
                       $0.score, $0.usableDuration, $0.segmentCount,
                       $0.cleanSegmentCount.map(String.init) ?? "旧缓存")
            } ?? "<旧缓存>"
            guard let embedding = embeddings[key] else {
                lines.append("声纹 \(key)：质量 \(qualityText)，未达到入选标准，未参与匹配")
                continue
            }
            if let quality, quality < minimumEmbeddingQuality {
                lines.append(String(format: "声纹 %@：质量 %@，低于 %.2f，保持未知",
                                    key, qualityText, minimumEmbeddingQuality))
                continue
            }

            // Multiple historical profiles can represent the same person under
            // old project scopes. Compare people, not duplicate profile rows.
            var byPerson: [String: (name: String, score: Float)] = [:]
            for profile in profiles {
                let normalized = HistoricalPersonAffiliations.normalizedName(profile.name)
                let score = matchScore(embedding, profile: profile)
                if byPerson[normalized] == nil || score > byPerson[normalized]!.score {
                    byPerson[normalized] = (profile.name, score)
                }
            }
            let scored = byPerson.values.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            guard let best = scored.first else { continue }
            let second = scored.dropFirst().first
            let margin = second.map { best.score - $0.score } ?? 1
            let runnerUp = second.map { "\($0.name) \(String(format: "%.2f", $0.score))" } ?? "<无>"

            let automaticSampleReady = qualityRecord.map {
                $0.score >= minimumAutomaticSampleQuality
                    && $0.usableDuration >= minimumAutomaticSampleDuration
                    && ($0.cleanSegmentCount.map { $0 > 0 } ?? true)
            } ?? false
            if automaticSampleReady
                && best.score >= automaticMatchThreshold && margin >= automaticAmbiguityMargin {
                names[speaker] = best.name
                lines.append(String(format: "声纹 %@：自动识别 %@；Top1 %.2f；Top2 %@；差值 %.2f；质量 %@",
                                    key, best.name, best.score, runnerUp, margin, qualityText))
            } else if best.score >= matchThreshold && margin >= ambiguityMargin {
                suggestions[speaker] = VoiceMatchSuggestion(
                    name: best.name, score: best.score, margin: margin, quality: quality)
                let reason = automaticSampleReady ? "匹配置信度不足" : "样本不足以自动确认"
                lines.append(String(format: "声纹 %@：候选 %@（%@）；Top1 %.2f；Top2 %@；差值 %.2f；质量 %@",
                                    key, best.name, reason, best.score, runnerUp, margin, qualityText))
            } else {
                lines.append(String(format: "声纹 %@：保持未知；Top1 %@ %.2f；Top2 %@；差值 %.2f；质量 %@",
                                    key, best.name, best.score, runnerUp, margin, qualityText))
            }
        }
        return MatchReport(names: names, suggestions: suggestions,
                           logDescription: lines.isEmpty ? "<空>" : lines.joined(separator: "\n"))
    }
}
