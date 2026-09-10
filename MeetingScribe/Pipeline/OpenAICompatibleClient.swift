import Foundation

/// Talks to any OpenAI-compatible `/chat/completions` endpoint.
///
/// DeepSeek, 智谱, Kimi, 通义, 硅基流动 and local runtimes (Ollama, LM Studio)
/// all expose this shape, so one client plus a preset table covers them
/// instead of a bespoke integration per vendor.
struct OpenAICompatibleClient {

    struct Completion: Sendable {
        let text: String
        let inputTokens: Int?
        let outputTokens: Int?
    }

    let baseURL: String
    let apiKey: String?
    let model: String
    /// Text-only models get OCR text; images are skipped rather than sent and rejected.
    let supportsVision: Bool
    var apiStyle: ProviderAPIStyle = .chatCompletions
    var httpHeaders: [String: String] = [:]

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
        try await completeDetailed(system: system, user: user, images: images,
                                   onProgress: onProgress).text
    }

    func completeDetailed(
        system: String,
        user: String,
        images: [Attachment],
        onProgress: @Sendable (String) -> Void = { _ in }
    ) async throws -> Completion {
        let debug = PipelineDebugRegistry.active
        let tool = (try? endpoint().absoluteString) ?? baseURL
        debug?.engineStart(tool: tool, arguments: [
            "model=\(model)", "apiStyle=\(String(describing: apiStyle))",
            "images=\(images.count)", "stream=true"
        ])
        do {
            let result = try await completeDetailedUnlogged(
                system: system, user: user, images: images, onProgress: onProgress)
            debug?.engineEnd(tool: tool, exitCode: 0, stdout: result.text, stderr: "")
            return result
        } catch {
            debug?.engineEnd(tool: tool, exitCode: -1, stdout: "", stderr: error.localizedDescription)
            throw error
        }
    }

    private func completeDetailedUnlogged(
        system: String,
        user: String,
        images: [Attachment],
        onProgress: @Sendable (String) -> Void
    ) async throws -> Completion {

        var content: [[String: Any]] = []

        if supportsVision {
            for image in images {
                content.append(["type": apiStyle == .responses ? "input_text" : "text", "text": image.caption])
                let dataURL = "data:image/jpeg;base64,\(image.jpeg.base64EncodedString())"
                if apiStyle == .responses {
                    content.append(["type": "input_image", "image_url": dataURL])
                } else {
                    content.append(["type": "image_url", "image_url": ["url": dataURL]])
                }
            }
        }
        content.append(["type": apiStyle == .responses ? "input_text" : "text", "text": user])

        // A model with no image parts is happier with a plain string body —
        // some gateways reject the array form when it holds only text.
        let userContent: Any = content.count == 1 ? user : content

        var body: [String: Any]
        if apiStyle == .responses {
            body = [
                "model": model,
                "instructions": system,
                "input": [["role": "user", "content": content]],
                "reasoning": ["effort": "xhigh"],
                "store": false,
                "stream": true,
            ]
        } else {
            body = [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": userContent],
                ],
                "stream": true,
            ]
            body[usesOpenAICompletionTokenParameter ? "max_completion_tokens" : "max_tokens"] = 8192
            if usesOpenAICompletionTokenParameter {
                body["stream_options"] = ["include_usage": true]
            }
        }

        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in httpHeaders { request.setValue(value, forHTTPHeaderField: name) }
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
        var outputFinished = false
        var inputTokens: Int?
        var outputTokens: Int?

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

            if let usage = event["usage"] as? [String: Any] {
                inputTokens = (usage["input_tokens"] ?? usage["prompt_tokens"]) as? Int
                outputTokens = (usage["output_tokens"] ?? usage["completion_tokens"]) as? Int
            }

            if apiStyle == .responses {
                let type = event["type"] as? String
                if type == "response.output_text.delta",
                   let chunk = event["delta"] as? String, !chunk.isEmpty {
                    text += chunk
                    if Date().timeIntervalSince(reportedAt) > 1.5 {
                        reportedAt = Date()
                        onProgress("已生成 \(text.count) 字…")
                    }
                } else if type == "response.reasoning_summary_text.delta",
                          Date().timeIntervalSince(reportedAt) > 1.5 {
                    reportedAt = Date()
                    onProgress("模型思考中…")
                } else if type == "response.in_progress" || type == "response.output_item.added" {
                    if Date().timeIntervalSince(reportedAt) > 1.5 {
                        reportedAt = Date()
                        onProgress("模型正在处理较长内容…")
                    }
                } else if type == "response.completed",
                          let response = event["response"] as? [String: Any] {
                    if text.isEmpty { text = Self.responseOutputText(from: response) }
                    if let usage = response["usage"] as? [String: Any] {
                        inputTokens = usage["input_tokens"] as? Int
                        outputTokens = usage["output_tokens"] as? Int
                    }
                    outputFinished = !text.isEmpty
                } else if type == "response.output_text.done" {
                    if text.isEmpty, let finalText = event["text"] as? String {
                        text = finalText
                    }
                    outputFinished = !text.isEmpty
                } else if type == "response.content_part.done",
                          let part = event["part"] as? [String: Any],
                          part["type"] as? String == "output_text" {
                    if text.isEmpty, let finalText = part["text"] as? String {
                        text = finalText
                    }
                    outputFinished = !text.isEmpty
                } else if type == "response.failed" {
                    let response = event["response"] as? [String: Any]
                    let failure = response?["error"] as? [String: Any]
                    throw Failure.stream(failure?["message"] as? String ?? "模型生成失败")
                } else if type == "response.incomplete" {
                    let response = event["response"] as? [String: Any]
                    let details = response?["incomplete_details"] as? [String: Any]
                    let reason = details?["reason"] as? String ?? "未知原因"
                    throw Failure.stream("模型未完成生成：\(reason)")
                }
                if outputFinished { break }
                continue
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
        return Completion(text: result, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// Some Responses-compatible gateways buffer deltas and only include text
    /// in the final `response.completed` event.
    static func responseOutputText(from response: [String: Any]) -> String {
        guard let output = response["output"] as? [[String: Any]] else { return "" }
        return output.compactMap { item -> String? in
            guard let content = item["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { part in
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }.joined()
        }.joined()
    }

    func endpoint() throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { throw Failure.noBaseURL }
        while base.hasSuffix("/") { base.removeLast() }
        // Accept either a bare base ("…/v1") or a full path pasted from docs.
        let suffix = apiStyle == .responses ? "/responses" : "/chat/completions"
        let path = base.hasSuffix(suffix) ? base : base + suffix
        guard let url = URL(string: path),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else { throw Failure.badBaseURL(path) }
        if scheme == "http", !Self.isLocalHost(url.host) {
            throw Failure.insecureRemoteURL(url.host ?? path)
        }
        return url
    }

    var usesOpenAICompletionTokenParameter: Bool {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?.lowercased() == "api.openai.com"
    }

    static func isLocalHost(_ rawHost: String?) -> Bool {
        guard let host = rawHost?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost")
            || host == "127.0.0.1" || host == "::1"
    }

    static func securityWarning(for baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "http",
              !isLocalHost(url.host) else { return nil }
        return "远程 HTTP 会明文发送 API key 和会议内容，请改用 HTTPS。"
    }

    enum Failure: LocalizedError {
        case noBaseURL
        case badBaseURL(String)
        case insecureRemoteURL(String)
        case http(Int, String)
        case stream(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .noBaseURL:
                return "未填写接口地址（Base URL）。"
            case .badBaseURL(let url):
                return "接口地址无效：\(url)"
            case .insecureRemoteURL(let host):
                return "拒绝连接不安全的远程 HTTP 地址（\(host)）。请使用 HTTPS；只有本机 localhost 服务允许 HTTP。"
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
