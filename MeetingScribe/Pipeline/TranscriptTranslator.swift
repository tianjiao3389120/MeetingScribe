import Foundation

struct TranscriptTranslator {
    let settings: Settings

    private struct Item: Codable { let id: Int; let text: String }

    func run(transcript: Transcript,
             progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [TranscriptTranslation] {
        var result: [TranscriptTranslation] = []
        // Claude CLI reads its credential from Keychain on process startup.
        // Keep the whole transcript in one invocation so macOS asks at most
        // once; remote APIs stay bounded to avoid gateway output limits.
        let batchSize = settings.backend == .claudeCLI ? max(transcript.segments.count, 1) : 80
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
            let raw = try await complete(system: system, user: payload)
            let parsed = try Self.parseResponse(raw)
            let expected = Set(batch.map(\.id))
            guard Set(parsed.map(\.segmentID)) == expected else { throw Failure.mismatchedSegments }
            result += parsed
            progress(index + 1, batches.count)
        }
        return result.sorted { $0.segmentID < $1.segmentID }
    }

    private func complete(system: String, user: String) async throws -> String {
        switch settings.backend {
        case .claudeCLI:
            let claude = try ToolLocator.require(.claude)
            let response = try await Shell.check(
                claude, ["-p", "--output-format", "text"],
                stdin: system + "\n\n" + user, timeout: 900)
            return response.stdout
        case .openAICompatible:
            return try await OpenAICompatibleClient(
                baseURL: settings.providerBaseURL, apiKey: settings.providerKey,
                model: settings.providerModel, supportsVision: false)
                .complete(system: system, user: user, images: [])
        case .anthropicAPI:
            guard let key = settings.apiKey, !key.isEmpty else { throw ToolError.noAPIKey }
            let body: [String: Any] = [
                "model": settings.apiModel, "max_tokens": 12000, "system": system,
                "messages": [["role": "user", "content": user]],
            ]
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 900
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = json["content"] as? [[String: Any]],
                  let text = blocks.compactMap({ $0["text"] as? String }).first else {
                throw Failure.emptyResponse
            }
            return text
        }
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
