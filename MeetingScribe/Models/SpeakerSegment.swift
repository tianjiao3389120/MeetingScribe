import Foundation

/// A stretch of audio attributed to one speaker.
struct SpeakerSegment: Codable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: Int
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
    var segments: [SpeakerSegment]
    /// Unit-length voiceprint per cluster, keyed by speaker id. Present when
    /// the recording was processed by a build that extracts them.
    var embeddings: [String: [Float]] = [:]
    /// Cluster id → enrolled person, filled in by voiceprint matching.
    var names: [Int: String] = [:]
    /// Per-meeting, user-confirmed organizational context. Never inferred from voiceprints.
    var roles: [Int: SpeakerRole] = [:]

    init(segments: [SpeakerSegment], embeddings: [String: [Float]] = [:],
         names: [Int: String] = [:], roles: [Int: SpeakerRole] = [:]) {
        self.segments = segments
        self.embeddings = embeddings
        self.names = names
        self.roles = roles
    }

    /// Older caches contain only `segments`; decode optional additions with
    /// defaults so an app update does not force expensive diarization again.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        segments = try values.decode([SpeakerSegment].self, forKey: .segments)
        embeddings = try values.decodeIfPresent([String: [Float]].self, forKey: .embeddings) ?? [:]
        names = try values.decodeIfPresent([Int: String].self, forKey: .names) ?? [:]
        roles = try values.decodeIfPresent([Int: SpeakerRole].self, forKey: .roles) ?? [:]
    }

    var speakerCount: Int { Set(segments.map(\.speaker)).count }

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
