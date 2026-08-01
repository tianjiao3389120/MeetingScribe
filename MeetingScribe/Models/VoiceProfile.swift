import Foundation

/// A person's enrolled voiceprint.
struct VoiceProfile: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// Unit-length mean of the samples enrolled so far.
    var embedding: [Float]
    var sampleCount: Int = 1
    var updatedAt: Date = Date()
    var note: String = ""

    /// Folds a new sample into the running mean, so a person's profile improves
    /// as they appear in more meetings rather than being replaced by the latest
    /// (possibly worse) recording.
    mutating func merge(_ sample: [Float]) {
        guard sample.count == embedding.count else { return }
        let weight = Float(sampleCount)
        var combined = zip(embedding, sample).map { ($0 * weight + $1) / (weight + 1) }
        let norm = sqrt(combined.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { combined = combined.map { $0 / norm } }
        embedding = combined
        sampleCount += 1
        updatedAt = Date()
    }
}

/// Enrolled voiceprints, persisted as one JSON file.
enum VoiceProfileStore {

    private static let fileURL: URL = {
        Diarizer.supportDirectory.appendingPathComponent("voice-profiles.json")
    }()

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
    static func enroll(samples: [(name: String, embedding: [Float], note: String)]) throws {
        var profiles = try loadChecked()
        for sample in samples {
            let trimmed = sample.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Failure.invalidName }
            guard !sample.embedding.isEmpty else { continue }

            if let index = profiles.firstIndex(where: { $0.name == trimmed }) {
                profiles[index].merge(sample.embedding)
                if !sample.note.isEmpty { profiles[index].note = sample.note }
            } else {
                profiles.append(VoiceProfile(name: trimmed, embedding: sample.embedding,
                                             note: sample.note))
            }
        }
        try save(profiles)
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
        try save(try loadChecked().filter { $0.id != id })
    }

    static func removeAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Best enrolled match per cluster.
    ///
    /// Rejects a match that is barely ahead of the next candidate: two people
    /// with similar voices should both stay anonymous rather than one being
    /// confidently mislabelled as the other. A name is also never assigned
    /// twice within one meeting — the stronger claim wins.
    static func match(embeddings: [String: [Float]]) -> [Int: String] {
        let profiles = load()
        guard !profiles.isEmpty, !embeddings.isEmpty else { return [:] }

        struct Candidate { let speaker: Int; let name: String; let score: Float }
        var candidates: [Candidate] = []

        for (key, embedding) in embeddings {
            guard let speaker = Int(key) else { continue }
            let scored = profiles
                .map { (name: $0.name, score: similarity(embedding, $0.embedding)) }
                .sorted { $0.score > $1.score }
            guard let best = scored.first, best.score >= matchThreshold else { continue }
            if scored.count > 1, best.score - scored[1].score < ambiguityMargin { continue }
            candidates.append(Candidate(speaker: speaker, name: best.name, score: best.score))
        }

        var result: [Int: String] = [:]
        var claimed = Set<String>()
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard !claimed.contains(candidate.name) else { continue }
            result[candidate.speaker] = candidate.name
            claimed.insert(candidate.name)
        }
        return result
    }
}
