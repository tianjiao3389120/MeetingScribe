import Foundation

struct TranscriptTranslator {
    let settings: Settings

    private struct Item: Codable { let id: Int; let text: String }

    func run(transcript: Transcript,
             progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [TranscriptTranslation] {
        var result: [TranscriptTranslation] = []
        // Local CLIs have startup overhead (and may read credentials from the
        // Keychain), so keep the transcript in one invocation. Remote APIs stay
        // bounded to avoid gateway output limits.
        let usesLocalCLI = settings.backend == .claudeCLI || settings.backend == .codexCLI
        let batchSize = usesLocalCLI ? max(transcript.segments.count, 1) : 80
        let client = try ModelTextClient(settings: settings)
        let batches = stride(from: 0, to: transcript.segments.count, by: batchSize).map {
            Array(transcript.segments[$0..<min($0 + batchSize, transcript.segments.count)])
        }
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let input = batch.map { Item(id: $0.id, text: $0.text) }
            let data = try JSONEncoder().encode(input)
            let payload = String(decoding: data, as: UTF8.self)
            let system = """
            你是香港商务会议逐字稿翻译员。把香港粤语、粤语夹英语或口语普通话转换为简体书面中文。
            保留公司名、产品名、缩写和自然的英文业务术语；不得总结、删减或补充事实。
            输入和输出都必须是 JSON 数组，逐项保留相同 id，只输出 [{"id":1,"text":"释义"}]。
            """
            let raw = try await client.complete(system: system, user: payload)
            let parsed = try Self.parseResponse(raw)
            let expected = Set(batch.map(\.id))
            guard Set(parsed.map(\.segmentID)) == expected else { throw Failure.mismatchedSegments }
            result += parsed
            progress(index + 1, batches.count)
        }
        return result.sorted { $0.segmentID < $1.segmentID }
    }

    static func parseResponse(_ raw: String) throws -> [TranscriptTranslation] {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = value.firstIndex(of: "["), let last = value.lastIndex(of: "]") {
            value = String(value[first...last])
        }
        guard let data = value.data(using: .utf8),
              let items = try? JSONDecoder().decode([Item].self, from: data),
              !items.isEmpty, items.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        else { throw Failure.invalidResponse }
        return items.map { TranscriptTranslation(segmentID: $0.id, text: $0.text) }
    }

    enum Failure: LocalizedError {
        case invalidResponse, mismatchedSegments, emptyResponse
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "模型返回的释义格式无法解析，请重试。"
            case .mismatchedSegments: return "模型遗漏了部分逐字稿片段，请重试。"
            case .emptyResponse: return "模型没有返回释义。"
            }
        }
    }
}
