import Foundation

/// A person's enrolled voiceprint.
struct VoiceProfile: Codable, Identifiable, Sendable {
    static let maximumRepresentativeSamples = 8

    var id: UUID = UUID()
    var name: String
    /// Unit-length mean of the samples enrolled so far.
    var embedding: [Float]
    /// A bounded set that preserves different microphones and acoustic
    /// conditions instead of collapsing every confirmation into one centroid.
    var representativeEmbeddings: [[Float]] = []
    var sampleCount: Int = 1
    var updatedAt: Date = Date()
    var note: String = ""
    /// Filename of a short, local reference clip used for manual identification.
    var referenceClip: String? = nil

    init(id: UUID = UUID(), name: String, embedding: [Float], sampleCount: Int = 1,
         updatedAt: Date = Date(), note: String = "", referenceClip: String? = nil,
         representativeEmbeddings: [[Float]]? = nil) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.representativeEmbeddings = representativeEmbeddings ?? (embedding.isEmpty ? [] : [embedding])
        self.sampleCount = sampleCount
        self.updatedAt = updatedAt
        self.note = note
        self.referenceClip = referenceClip
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, embedding, representativeEmbeddings, sampleCount, updatedAt, note, referenceClip
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        embedding = try values.decode([Float].self, forKey: .embedding)
        representativeEmbeddings = try values.decodeIfPresent(
            [[Float]].self, forKey: .representativeEmbeddings) ?? (embedding.isEmpty ? [] : [embedding])
        sampleCount = try values.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 1
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

            if let index = profiles.firstIndex(where: { $0.name == trimmed }) {
                profiles[index].merge(sample.embedding)
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
        var seen = Set<String>()
        var normalized = profiles
        for index in normalized.indices {
            let name = normalized[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw Failure.invalidName }
            guard seen.insert(name).inserted else { throw Failure.duplicateName(name) }
            normalized[index].name = name
            normalized[index].updatedAt = Date()
        }
        try save(normalized)
    }

    static func remove(id: UUID) throws {
        let profiles = try loadChecked()
        if let profile = profiles.first(where: { $0.id == id }), let clip = referenceClipURL(for: profile) {
            try? FileManager.default.removeItem(at: clip)
        }
        try save(profiles.filter { $0.id != id })
    }

    static func removeAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: clipsDirectory)
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
    static func match(embeddings: [String: [Float]]) -> [Int: String] {
        match(embeddings: embeddings, profiles: load())
    }

    static func match(embeddings: [String: [Float]], profiles: [VoiceProfile]) -> [Int: String] {
        guard !profiles.isEmpty, !embeddings.isEmpty else { return [:] }

        struct Candidate { let speaker: Int; let name: String; let score: Float }
        var candidates: [Candidate] = []

        for (key, embedding) in embeddings {
            guard let speaker = Int(key) else { continue }
            let scored = profiles
                .map { (name: $0.name, score: matchScore(embedding, profile: $0)) }
                .sorted { $0.score > $1.score }
            guard let best = scored.first, best.score >= matchThreshold else { continue }
            if scored.count > 1, best.score - scored[1].score < ambiguityMargin { continue }
            candidates.append(Candidate(speaker: speaker, name: best.name, score: best.score))
        }

        return Dictionary(uniqueKeysWithValues: candidates.map { ($0.speaker, $0.name) })
    }
}
