import Foundation

/// A stretch of audio attributed to one speaker.
struct SpeakerSegment: Codable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: Int
}

/// Speaker timeline for a recording, with the lookup the transcript needs.
struct Diarization: Codable, Sendable {
    var segments: [SpeakerSegment]

    var speakerCount: Int { Set(segments.map(\.speaker)).count }

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
