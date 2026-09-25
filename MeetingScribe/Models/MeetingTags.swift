import Foundation

enum MeetingTags {
    static func parse(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { value in
                guard !value.isEmpty else { return false }
                return seen.insert(key(value)).inserted
            }
    }

    static func suggestions(from records: [MeetingRecord]) -> [String] {
        var values: [String: (name: String, count: Int)] = [:]
        for record in records {
            for tag in record.tags ?? [] {
                let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let normalized = key(name)
                let current = values[normalized]
                values[normalized] = (current?.name ?? name, (current?.count ?? 0) + 1)
            }
        }
        return values.values.sorted {
            $0.count == $1.count
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.count > $1.count
        }.map(\.name)
    }

    static func toggling(_ tag: String, in text: String) -> String {
        var tags = parse(text)
        if let index = tags.firstIndex(where: { key($0) == key(tag) }) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        return tags.joined(separator: ", ")
    }

    static func contains(_ tag: String, in text: String) -> Bool {
        parse(text).contains { key($0) == key(tag) }
    }

    static func syncingMeetingType(_ meetingType: String, in tags: [String],
                                   knownTypes: [String]) -> [String] {
        let known = Set(knownTypes.map(key))
        var result = tags.filter { !known.contains(key($0)) }
        let cleaned = meetingType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty, !result.contains(where: { key($0) == key(cleaned) }) {
            result.append(cleaned)
        }
        return result
    }

    private static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
