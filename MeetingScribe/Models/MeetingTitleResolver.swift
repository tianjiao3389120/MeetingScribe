import Foundation

enum MeetingTitleResolver {
    private static let genericTitles: Set<String> = [
        "会议", "会议纪要", "会议记录", "会议总结", "项目会议", "工作会议",
        "未命名会议", "meeting", "meeting minutes", "meeting notes",
    ]

    static func resolve(requestedTitle: String, sourceURL: URL,
                        generatedTitle: String?) -> String {
        let requested = cleaned(requestedTitle)
        let sourceTitle = cleaned(sourceURL.deletingPathExtension().lastPathComponent)

        // A title different from the source filename was explicitly supplied by
        // the user (or retained from an earlier edit) and must never be replaced.
        guard comparable(requested) == comparable(sourceTitle) else { return requested }
        guard let generatedTitle else { return requested }
        let generated = cleaned(generatedTitle)
        guard isUseful(generated) else { return requested }
        return generated.count > 36 ? String(generated.prefix(36)) + "…" : generated
    }

    static func historicalTitle(for record: MeetingRecord) -> String? {
        let resolved = resolve(requestedTitle: record.title, sourceURL: record.sourceURL,
                               generatedTitle: record.structuredSummary?.title)
        return comparable(resolved) == comparable(cleaned(record.title)) ? nil : resolved
    }

    private static func cleaned(_ value: String) -> String {
        var result = value
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for prefix in ["会议名称：", "会议名称:", "标题：", "标题:"] where result.hasPrefix(prefix) {
            result.removeFirst(prefix.count)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "#*`“”\"'「」『』【】 "))
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func comparable(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func isUseful(_ value: String) -> Bool {
        let normalized = comparable(value)
        return value.count >= 4 && !genericTitles.contains(normalized)
    }
}
