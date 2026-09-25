import Foundation

/// A stretch of audio attributed to one speaker.
struct SpeakerSegment: Codable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: Int
}

struct VoiceEmbeddingQuality: Codable, Sendable, Equatable {
    let score: Float
    let usableDuration: TimeInterval
    let segmentCount: Int
    /// Nil for legacy caches. New runs report how many selected chunks were
    /// free of detected overlap with another speaker.
    let cleanSegmentCount: Int?

    init(score: Float, usableDuration: TimeInterval, segmentCount: Int,
         cleanSegmentCount: Int? = nil) {
        self.score = score
        self.usableDuration = usableDuration
        self.segmentCount = segmentCount
        self.cleanSegmentCount = cleanSegmentCount
    }
}

struct VoiceReferenceSegment: Codable, Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let quality: Float
    let isClean: Bool

    var duration: TimeInterval { max(0, end - start) }
    var isEnrollmentReady: Bool {
        isClean && quality >= VoiceProfileStore.minimumAutomaticSampleQuality
            && duration >= VoiceProfileStore.minimumAutomaticSampleDuration
    }
}

struct VoiceMatchSuggestion: Codable, Sendable, Equatable {
    let name: String
    let score: Float
    let margin: Float
    let quality: Float?
}

struct SpeakerRole: Codable, Sendable, Equatable {
    enum Affiliation: String, Codable, CaseIterable, Sendable, Identifiable {
        case unknown, customer, ours, thirdParty
        var id: String { rawValue }
        var label: String {
            switch self {
            case .unknown: return "未确认"
            case .customer: return "客户"
            case .ours: return "我司"
            case .thirdParty: return "第三方"
            }
        }
    }

    enum MeetingRole: String, Codable, CaseIterable, Sendable, Identifiable {
        case unknown, leader, projectManager, sales, engineer, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .unknown: return "未确认"
            case .leader: return "领导"
            case .projectManager: return "项目经理"
            case .sales: return "Sales"
            case .engineer: return "工程师"
            case .other: return "其他"
            }
        }

        static func directoryValue(_ value: String) -> MeetingRole {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty || normalized == "未确认" { return .unknown }
            return allCases.first {
                $0.rawValue.lowercased() == normalized || $0.label.lowercased() == normalized
            } ?? .other
        }
    }

    var affiliation: Affiliation = .unknown
    var meetingRole: MeetingRole = .unknown

    var isSpecified: Bool { affiliation != .unknown || meetingRole != .unknown }
    var promptSuffix: String {
        [affiliation == .unknown ? nil : affiliation.label,
         meetingRole == .unknown ? nil : meetingRole.label]
            .compactMap { $0 }.joined(separator: "｜")
    }

    static func applying(_ role: SpeakerRole, to speaker: Int,
                         names: [Int: String], roles: [Int: SpeakerRole]) -> [Int: SpeakerRole] {
        var result = roles
        result[speaker] = role
        let sourceName = normalizedName(names[speaker])
        guard !sourceName.isEmpty else { return result }
        for (candidate, name) in names where normalizedName(name) == sourceName {
            result[candidate] = role
        }
        return result
    }

    private static func normalizedName(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Speaker timeline for a recording, with the lookup the transcript needs.
struct Diarization: Codable, Sendable {
    /// New runs are clustered at this boundary by the engine. Applying the
    /// same conservative rule to residual rows also makes older cached runs
    /// understandable without rewriting their speaker timeline.
    static let conservativeClusterSimilarity: Float = 0.72
    static let minimumGroupingQuality: Float = 0.58
    static let maximumFragmentDuration: TimeInterval = 12
    var segments: [SpeakerSegment]
    /// Unit-length voiceprint per cluster, keyed by speaker id. Present when
    /// the recording was processed by a build that extracts them.
    var embeddings: [String: [Float]] = [:]
    /// Quality of the clean speech used to build each cluster embedding.
    var embeddingQualities: [String: VoiceEmbeddingQuality] = [:]
    /// Best audible candidate per cluster. Unlike the raw longest turn, this
    /// range has passed the same overlap/noise checks used for the embedding.
    var referenceSegments: [String: VoiceReferenceSegment] = [:]
    /// Cluster id → enrolled person, filled in by voiceprint matching.
    var names: [Int: String] = [:]
    /// Medium-confidence candidates are shown for confirmation but never sent
    /// to downstream models as if they were confirmed identities.
    var nameSuggestions: [Int: VoiceMatchSuggestion] = [:]
    /// Per-meeting, user-confirmed organizational context. Never inferred from voiceprints.
    var roles: [Int: SpeakerRole] = [:]

    init(segments: [SpeakerSegment], embeddings: [String: [Float]] = [:],
         embeddingQualities: [String: VoiceEmbeddingQuality] = [:],
         referenceSegments: [String: VoiceReferenceSegment] = [:],
         names: [Int: String] = [:],
         nameSuggestions: [Int: VoiceMatchSuggestion] = [:],
         roles: [Int: SpeakerRole] = [:]) {
        self.segments = segments
        self.embeddings = embeddings
        self.embeddingQualities = embeddingQualities
        self.referenceSegments = referenceSegments
        self.names = names
        self.nameSuggestions = nameSuggestions
        self.roles = roles
    }

    /// Older caches contain only `segments`; decode optional additions with
    /// defaults so an app update does not force expensive diarization again.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        segments = try values.decode([SpeakerSegment].self, forKey: .segments)
        embeddings = try values.decodeIfPresent([String: [Float]].self, forKey: .embeddings) ?? [:]
        embeddingQualities = try values.decodeIfPresent(
            [String: VoiceEmbeddingQuality].self, forKey: .embeddingQualities) ?? [:]
        referenceSegments = try values.decodeIfPresent(
            [String: VoiceReferenceSegment].self, forKey: .referenceSegments) ?? [:]
        names = try values.decodeIfPresent([Int: String].self, forKey: .names) ?? [:]
        nameSuggestions = try values.decodeIfPresent(
            [Int: VoiceMatchSuggestion].self, forKey: .nameSuggestions) ?? [:]
        roles = try values.decodeIfPresent([Int: SpeakerRole].self, forKey: .roles) ?? [:]
    }

    var speakerCount: Int { Set(segments.map(\.speaker)).count }

    var fragmentationWarning: String? {
        guard speakerCount >= 8 else { return nil }
        let durations = Dictionary(grouping: segments, by: \.speaker).mapValues {
            $0.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        }
        let short = durations.values.filter { $0 < 6 }.count
        let suspiciousShare = Double(short) / Double(max(speakerCount, 1))
        guard speakerCount >= 15 || suspiciousShare >= 0.35 else { return nil }
        return "检测到 \(speakerCount) 个声纹簇，其中 \(short) 个发言不足 6 秒，可能存在同一人被拆分。可先确认相似声纹；若人数明显不符，再指定实际发言人数重新分离。"
    }

    var clusterDiagnosticsDescription: String {
        let similar = conservativeClusterGroups().filter { $0.count > 1 }
        let groupedClusters = similar.reduce(0) { $0 + $1.count }
        return "声纹簇：\(speakerCount)；疑似分裂分组：\(similar.count) 组 / \(groupedClusters) 个簇；异常提示：\(fragmentationWarning ?? "无")"
    }

    /// Groups only near-identical, non-overlapping clusters. Complete-link
    /// comparison prevents a loose A≈B≈C chain from merging unlike A and C.
    /// This is used to reduce confirmation rows, not to silently rewrite the
    /// diarization timeline sent to the minutes model.
    func conservativeClusterGroups(
        threshold: Float = Diarization.conservativeClusterSimilarity
    ) -> [[Int]] {
        let durations = Dictionary(grouping: segments, by: \.speaker).mapValues {
            $0.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        }
        let speakers = Set(segments.map(\.speaker)).sorted {
            let lhs = durations[$0, default: 0], rhs = durations[$1, default: 0]
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        var groups: [[Int]] = []
        for speaker in speakers {
            guard let embedding = embeddings["\(speaker)"] else {
                groups.append([speaker]); continue
            }
            if let index = groups.firstIndex(where: { group in
                group.allSatisfy { member in
                    guard let other = embeddings["\(member)"] else { return false }
                    let speakerDuration = durations[speaker, default: 0]
                    let memberDuration = durations[member, default: 0]
                    let speakerQuality = embeddingQualities["\(speaker)"]?.score ?? 1
                    let memberQuality = embeddingQualities["\(member)"]?.score ?? 1
                    return min(speakerDuration, memberDuration)
                            <= Diarization.maximumFragmentDuration
                        && min(speakerQuality, memberQuality)
                            >= Diarization.minimumGroupingQuality
                        && VoiceProfileStore.similarity(embedding, other) >= threshold
                        && !clustersOverlap(speaker, member)
                }
            }) {
                groups[index].append(speaker)
            } else {
                groups.append([speaker])
            }
        }
        return groups.map { $0.sorted() }
    }

    private func clustersOverlap(_ first: Int, _ second: Int) -> Bool {
        guard first != second else { return false }
        let lhs = segments.filter { $0.speaker == first }
        let rhs = segments.filter { $0.speaker == second }
        return lhs.contains { a in
            rhs.contains { b in min(a.end, b.end) - max(a.start, b.start) > 0.12 }
        }
    }

    /// What to call a speaker: their enrolled name if recognised, else the
    /// prominence-ordered letter.
    func displayName(for speaker: Int) -> String {
        let name = names[speaker] ?? "说话人\(labels[speaker] ?? "\(speaker)")"
        guard let role = roles[speaker], role.isSpecified else { return name }
        return "\(name)｜\(role.promptSuffix)"
    }

    /// Speaker owning the largest share of `[start, end)`.
    ///
    /// Overlap rather than midpoint: a transcript line often straddles a turn
    /// boundary, and whoever holds most of it is the better attribution.
    func speaker(from start: TimeInterval, to end: TimeInterval) -> Int? {
        var best: Int?
        var bestOverlap: TimeInterval = 0
        for segment in segments {
            let overlap = min(end, segment.end) - max(start, segment.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = segment.speaker
            }
        }
        return best
    }

    /// Share of total speech per speaker, most talkative first — used to label
    /// them by prominence rather than by arbitrary cluster id.
    var ranking: [(speaker: Int, seconds: TimeInterval)] {
        var totals: [Int: TimeInterval] = [:]
        for segment in segments {
            totals[segment.speaker, default: 0] += segment.end - segment.start
        }
        return totals.sorted { $0.value > $1.value }.map { (speaker: $0.key, seconds: $0.value) }
    }

    /// Stable display labels: 说话人A is whoever spoke most.
    var labels: [Int: String] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var result: [Int: String] = [:]
        for (index, entry) in ranking.enumerated() {
            result[entry.speaker] = index < alphabet.count
                ? String(alphabet[index])
                : "\(index + 1)"
        }
        return result
    }
}
