import Foundation

struct RecognitionMemoryEntry: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case term, person, company, product, acronym
        var id: String { rawValue }
        var label: String {
            switch self {
            case .term: return "术语"
            case .person: return "人名"
            case .company: return "公司"
            case .product: return "产品"
            case .acronym: return "缩写"
            }
        }
    }

    var id: UUID = UUID()
    /// What speech recognition produced. Empty means prompt-only vocabulary.
    var mistaken: String = ""
    var canonical: String
    var kind: Kind = .term
    /// Nil entries are global; non-nil entries only apply to one workspace.
    var workspaceID: UUID? = nil
    var sourceTitle: String = ""
    var usageCount: Int = 0
    /// Optional for backward-compatible decoding of memories created before
    /// prompt usage was tracked separately from literal corrections.
    var promptUsageCount: Int? = nil
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

enum RecognitionMemoryStore {
    static let directory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingScribe/RecognitionMemory", isDirectory: true)
    static let entriesURL = directory.appendingPathComponent("entries.json")

    static func load(from url: URL = entriesURL) -> [RecognitionMemoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecognitionMemoryEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [RecognitionMemoryEntry], to url: URL = entriesURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @discardableResult
    static func upsert(_ entry: RecognitionMemoryEntry, to url: URL = entriesURL) throws -> RecognitionMemoryEntry {
        var entries = load(from: url)
        var value = entry
        value.mistaken = value.mistaken.trimmingCharacters(in: .whitespacesAndNewlines)
        value.canonical = value.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.canonical.isEmpty else { return value }
        value.updatedAt = Date()
        if let index = entries.firstIndex(where: {
            $0.workspaceID == value.workspaceID && $0.kind == value.kind
                && $0.mistaken.caseInsensitiveCompare(value.mistaken) == .orderedSame
                && $0.canonical.caseInsensitiveCompare(value.canonical) == .orderedSame
        }) {
            value.id = entries[index].id
            value.createdAt = entries[index].createdAt
            value.usageCount = entries[index].usageCount
            value.promptUsageCount = entries[index].promptUsageCount
            entries[index] = value
        } else {
            entries.append(value)
        }
        try save(entries, to: url)
        return value
    }

    static func remove(id: UUID, from url: URL = entriesURL) throws {
        try save(load(from: url).filter { $0.id != id }, to: url)
    }

    @discardableResult
    static func update(_ entry: RecognitionMemoryEntry,
                       in url: URL = entriesURL) throws -> RecognitionMemoryEntry {
        var entries = load(from: url)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return try upsert(entry, to: url)
        }
        var value = entry
        value.mistaken = value.mistaken.trimmingCharacters(in: .whitespacesAndNewlines)
        value.canonical = value.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.canonical.isEmpty else { return entries[index] }
        value.createdAt = entries[index].createdAt
        value.usageCount = entries[index].usageCount
        value.promptUsageCount = entries[index].promptUsageCount
        value.updatedAt = Date()
        entries[index] = value
        try save(entries, to: url)
        return value
    }

    static func relevant(workspaceID: UUID?, text: String = "",
                         from url: URL = entriesURL) -> [RecognitionMemoryEntry] {
        let context = text.lowercased()
        return load(from: url).filter {
            $0.isEnabled && ($0.workspaceID == nil || $0.workspaceID == workspaceID)
        }.sorted { lhs, rhs in
            let l = score(lhs, workspaceID: workspaceID, context: context)
            let r = score(rhs, workspaceID: workspaceID, context: context)
            return l == r ? lhs.updatedAt > rhs.updatedAt : l > r
        }
    }

    static func prompt(workspaceID: UUID?, context: String = "",
                       from url: URL = entriesURL) -> String {
        relevant(workspaceID: workspaceID, text: context, from: url).prefix(36).map {
            // Whisper's initial prompt is a vocabulary bias, not an instruction
            // interpreter. Sending the mistaken spelling back to it can reinforce
            // the very error that local correction is meant to repair.
            return $0.canonical
        }.joined(separator: "，")
    }

    /// Records entries actually passed to a new transcription. Cache hits must
    /// not call this because Whisper was not invoked in that case.
    static func recordPromptUsage(workspaceID: UUID?, context: String = "",
                                  from url: URL = entriesURL) {
        let selected = relevant(workspaceID: workspaceID, text: context, from: url).prefix(36)
        let ids = Set(selected.map(\.id))
        guard !ids.isEmpty else { return }
        var all = load(from: url)
        for index in all.indices where ids.contains(all[index].id) {
            all[index].promptUsageCount = (all[index].promptUsageCount ?? 0) + 1
            all[index].updatedAt = Date()
        }
        try? save(all, to: url)
    }

    static func apply(to transcript: Transcript, workspaceID: UUID?,
                      from url: URL = entriesURL) -> Transcript {
        let pairs = relevant(workspaceID: workspaceID, text: transcript.plainText, from: url)
            .filter { !$0.mistaken.isEmpty && $0.mistaken != $0.canonical && $0.mistaken.count >= 2 }
        guard !pairs.isEmpty else { return transcript }
        var result = transcript
        var used = Set<UUID>()
        for index in result.segments.indices {
            var text = result.segments[index].text
            for entry in pairs {
                let changed = safeReplace(entry.mistaken, with: entry.canonical, in: text)
                if changed != text { used.insert(entry.id); text = changed }
            }
            result.segments[index].text = text
        }
        if !used.isEmpty {
            var all = load(from: url)
            for index in all.indices where used.contains(all[index].id) {
                all[index].usageCount += 1; all[index].updatedAt = Date()
            }
            try? save(all, to: url)
        }
        return result
    }

    /// Finds a single contiguous correction per edited segment. This avoids
    /// inventing word pairs when a user rewrites an entire sentence.
    static func correctionSuggestions(original: Transcript, edited: Transcript,
                                      workspaceID: UUID?, sourceTitle: String) -> [RecognitionMemoryEntry] {
        zip(original.segments, edited.segments).compactMap { before, after in
            guard before.text != after.text,
                  let pair = singleChange(from: before.text, to: after.text),
                  !pair.0.isEmpty, !pair.1.isEmpty,
                  pair.0.count <= 40, pair.1.count <= 40 else { return nil }
            return RecognitionMemoryEntry(mistaken: pair.0, canonical: pair.1,
                                          workspaceID: workspaceID, sourceTitle: sourceTitle)
        }
    }

    private static func score(_ entry: RecognitionMemoryEntry, workspaceID: UUID?, context: String) -> Int {
        var value = entry.usageCount * 3
        if entry.workspaceID != nil && entry.workspaceID == workspaceID { value += 100 }
        if context.contains(entry.canonical.lowercased()) ||
            (!entry.mistaken.isEmpty && context.contains(entry.mistaken.lowercased())) { value += 30 }
        if entry.kind == .person { value += 4 }
        return value
    }

    private static func safeReplace(_ source: String, with replacement: String, in text: String) -> String {
        let latin = source.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
        guard latin else { return text.replacingOccurrences(of: source, with: replacement) }
        let escaped = NSRegularExpression.escapedPattern(for: source)
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])", options: .caseInsensitive) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    private static func singleChange(from old: String, to new: String) -> (String, String)? {
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count - prefix, b.count - prefix),
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let left = String(a[prefix..<(a.count - suffix)]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(b[prefix..<(b.count - suffix)]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (left, right)
    }
}

enum RecognitionCandidateExtractor {
    static func candidates(from uncertainties: [StructuredMinutes.EvidenceItem]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for item in uncertainties {
            if item.uncertaintyKind == .unclearMeaning { continue }
            let quoted = quotedValues(in: item.content)
            let fallback = markedValues(in: item.content)
            for raw in quoted.isEmpty ? fallback : quoted {
                let value = raw.replacingOccurrences(of: "〔音〕", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isEligible = item.uncertaintyKind == .speechRecognition || isLearnable(value)
                guard isEligible, seen.insert(value.lowercased()).inserted else { continue }
                result.append(value)
            }
        }
        return result
    }

    private static func isLearnable(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 40 else { return false }
        if value.rangeOfCharacter(from: .decimalDigits) != nil { return false }
        if value.range(of: #"[，。！？；：、]"#, options: .regularExpression) != nil { return false }
        // Time/version descriptions are facts to verify in this meeting, not
        // reusable vocabulary that should influence future transcription.
        let factWords = ["年底", "年初", "月初", "月末", "分钟", "小时"]
        if factWords.contains(where: value.contains) { return false }
        if value.contains("的版本") || value.contains("版本的") { return false }
        // Quoted uncertainty text is often a whole sentence rather than a term.
        // Keep short names/terms, but reject conversational predicates and
        // report-style wording so the learning UI does not suggest phrases like
        // “GIB哪边IBS哪边去做UAT”.
        let sentenceMarkers = ["哪边", "哪里", "怎么", "如何", "去做", "先做", "需要", "可以", "表示",
                               "关于", "环境", "方案", "工具", "无法", "不清", "确认", "建议", "后续", "具体"]
        if sentenceMarkers.contains(where: value.contains) { return false }
        let chineseCount = value.unicodeScalars.filter { 0x4E00...0x9FFF ~= $0.value }.count
        if chineseCount >= 4 && value.count > 12 { return false }
        return true
    }

    private static func quotedValues(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"[“\"「『]([^”\"」』]{1,40})[”\"」』]"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[valueRange])
        }
    }

    private static func markedValues(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([^，。；！？、\s]{1,20})〔音〕"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
