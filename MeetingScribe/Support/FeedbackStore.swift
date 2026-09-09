import Foundation

enum FeedbackStore {
    static let directory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingScribe/Feedback", isDirectory: true)
    static let candidatesURL = directory.appendingPathComponent("glossary-candidates.json")

    static func load(meetingID: UUID, root: URL = directory) -> MeetingFeedback? {
        try? JSONDecoder.withISO8601.decode(
            MeetingFeedback.self,
            from: Data(contentsOf: root.appendingPathComponent("\(meetingID).json")))
    }

    static func save(_ feedback: MeetingFeedback, root: URL = directory) throws {
        try prepare(root)
        try JSONEncoder.withISO8601.encode(feedback).write(
            to: root.appendingPathComponent("\(feedback.meetingID).json"), options: .atomic)
    }

    static func loadCandidates(from url: URL = candidatesURL) -> [GlossaryCandidate] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.withISO8601.decode([GlossaryCandidate].self, from: data)) ?? []
    }

    static func addCandidates(_ terms: [String], meetingID: UUID, title: String,
                              to url: URL = candidatesURL) throws {
        var values = loadCandidates(from: url)
        var existing = Set(values.map { $0.term.lowercased() })
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, existing.insert(term.lowercased()).inserted else { continue }
            values.append(GlossaryCandidate(term: term, meetingID: meetingID, sourceTitle: title))
        }
        try prepare(url.deletingLastPathComponent())
        try JSONEncoder.withISO8601.encode(values).write(to: url, options: .atomic)
    }

    static func removeCandidate(id: UUID, from url: URL = candidatesURL) throws {
        let values = loadCandidates(from: url).filter { $0.id != id }
        try prepare(url.deletingLastPathComponent())
        try JSONEncoder.withISO8601.encode(values).write(to: url, options: .atomic)
    }

    private static func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private extension JSONEncoder {
    static var withISO8601: JSONEncoder {
        let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value
    }
}

private extension JSONDecoder {
    static var withISO8601: JSONDecoder {
        let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value
    }
}
