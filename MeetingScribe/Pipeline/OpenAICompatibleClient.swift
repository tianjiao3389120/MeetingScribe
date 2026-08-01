import Foundation

/// Talks to any OpenAI-compatible `/chat/completions` endpoint.
///
/// DeepSeek, 智谱, Kimi, 通义, 硅基流动 and local runtimes (Ollama, LM Studio)
/// all expose this shape, so one client plus a preset table covers them
/// instead of a bespoke integration per vendor.
struct OpenAICompatibleClient {

    let baseURL: String
    let apiKey: String?
    let model: String
    /// Text-only models get OCR text; images are skipped rather than sent and rejected.
    let supportsVision: Bool

    struct Attachment {
        let caption: String
        let jpeg: Data
    }

    func complete(
        system: String,
        user: String,
        images: [Attachment],
        onProgress: @Sendable (String) -> Void = { _ in }
    ) async throws -> String {

        var content: [[String: Any]] = []

        if supportsVision {
            for image in images {
                content.append(["type": "text", "text": image.caption])
                content.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(image.jpeg.base64EncodedString())"],
                ])
            }
        }
        content.append(["type": "text", "text": user])

        // A model with no image parts is happier with a plain string body —
        // some gateways reject the array form when it holds only text.
        let userContent: Any = content.count == 1 ? user : content

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ],
            "stream": true,
            "max_tokens": 8192,
        ]

        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 900

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var detail = ""
            for try await line in bytes.lines where detail.count < 800 { detail += line }
            throw Failure.http(http.statusCode, detail)
        }

        var text = ""
        var reportedAt = Date.distantPast

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let error = event["error"] as? [String: Any] {
                throw Failure.stream(error["message"] as? String ?? "未知错误")
            }

            guard let choices = event["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }

            // Reasoning models stream their chain-of-thought in a separate
            // field; it is progress, not part of the summary.
            if let chunk = delta["content"] as? String, !chunk.isEmpty {
                text += chunk
                if Date().timeIntervalSince(reportedAt) > 1.5 {
                    reportedAt = Date()
                    onProgress("已生成 \(text.count) 字…")
                }
            } else if delta["reasoning_content"] is String,
                      Date().timeIntervalSince(reportedAt) > 1.5 {
                reportedAt = Date()
                onProgress("模型思考中…")
            }
        }

        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw Failure.empty }
        return result
    }

    private func endpoint() throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { throw Failure.noBaseURL }
        while base.hasSuffix("/") { base.removeLast() }
        // Accept either a bare base ("…/v1") or a full path pasted from docs.
        let path = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: path) else { throw Failure.badBaseURL(path) }
        return url
    }

    enum Failure: LocalizedError {
        case noBaseURL
        case badBaseURL(String)
        case http(Int, String)
        case stream(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .noBaseURL:
                return "未填写接口地址（Base URL）。"
            case .badBaseURL(let url):
                return "接口地址无效：\(url)"
            case .http(401, _), .http(403, _):
                return "API key 无效或无权限。"
            case .http(404, let detail):
                return "接口地址不对（404）。请检查 Base URL 是否包含 /v1 之类的前缀。\n\(detail.prefix(200))"
            case .http(429, _):
                return "触发速率限制或余额不足，请稍后重试。"
            case .http(let code, let detail):
                return "服务返回 \(code)：\(detail.prefix(300))"
            case .stream(let message):
                return "生成中断：\(message)"
            case .empty:
                return "模型没有返回内容。可能是上下文超长，试试关闭画面分析或换用长上下文模型。"
            }
        }
    }
}
