import Foundation

/// One timestamped line of speech.
struct TranscriptSegment: Identifiable, Codable, Sendable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    var text: String

    var timecode: String { TranscriptSegment.timecode(start) }

    /// Position marker: mm:ss, or h:mm:ss once past an hour.
    static func timecode(_ t: TimeInterval) -> String {
        let total = max(Int(t.rounded()), 0)
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// Human-readable length. Never rounds a real recording down to "0 分钟" —
    /// short clips report in seconds instead.
    static func humanDuration(_ t: TimeInterval) -> String {
        let total = max(Int(t.rounded()), 0)
        if total < 60 { return "\(total) 秒" }

        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        if hours > 0 {
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(hours) 小时"
        }
        // Under ten minutes the seconds still carry information; above that
        // they're noise.
        return (minutes < 10 && seconds > 0) ? "\(minutes) 分 \(seconds) 秒" : "\(minutes) 分钟"
    }
}

struct Transcript: Codable, Sendable {
    var segments: [TranscriptSegment]

    var plainText: String {
        segments.map(\.text).joined(separator: "\n")
    }

    /// Transcript with a timecode on every line — this is what the analysis
    /// prompt receives, so the model can cross-reference screen captures.
    var timecodedText: String {
        segments.map { "[\($0.timecode)] \($0.text)" }.joined(separator: "\n")
    }

    var duration: TimeInterval { segments.last?.end ?? 0 }

    /// Applies one edited text line to each existing timed segment. Timecodes
    /// shown in the editor are labels only; original timing remains authoritative.
    func replacingTexts(from edited: String) -> Transcript? {
        let lines = edited.components(separatedBy: .newlines)
        guard lines.count == segments.count else { return nil }
        var values: [TranscriptSegment] = []
        for (segment, line) in zip(segments, lines) {
            let value: String
            if let close = line.firstIndex(of: "]"), line.first == "[" {
                value = String(line[line.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                value = line.trimmingCharacters(in: .whitespaces)
            }
            guard !value.isEmpty else { return nil }
            values.append(TranscriptSegment(id: segment.id, start: segment.start,
                                            end: segment.end, text: value))
        }
        return Transcript(segments: values)
    }

    /// Parses whisper.cpp's SRT output.
    static func parse(srt: String) -> Transcript {
        var segments: [TranscriptSegment] = []
        for block in srt.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count >= 3, lines[1].contains("-->") else { continue }
            let bounds = lines[1].components(separatedBy: "-->")
            guard bounds.count == 2,
                  let start = parseTimecode(bounds[0]),
                  let end = parseTimecode(bounds[1]) else { continue }
            let text = lines[2...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            segments.append(TranscriptSegment(id: segments.count, start: start, end: end, text: text))
        }
        return Transcript(segments: segments)
    }

    /// "00:12:34,120" → seconds
    private static func parseTimecode(_ raw: String) -> TimeInterval? {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2])
        else { return nil }
        return h * 3600 + m * 60 + s
    }
}
