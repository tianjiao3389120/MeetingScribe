import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Turns the assembled timeline into a meeting summary.
///
/// Two backends: the local `claude` CLI (uses an existing subscription, costs
/// nothing extra) and the Anthropic API (works on any machine with a key).
/// Same prompt either way, so output is comparable.
struct Analyzer {

    struct Result: Sendable {
        let markdown: String
        let structured: StructuredMinutes?
        /// Raw model output is retained when JSON parsing failed, so a useful
        /// legacy Markdown response is never discarded.
        let usedFallback: Bool
    }

    let assets: MeetingAssets
    let settings: Settings

    func run(progress: @escaping @Sendable (String) -> Void) async throws -> Result {
        // Only offer images to a backend that can actually take them; otherwise
        // every capture goes in as OCR text and nothing is silently dropped.
        let canSendImages: Bool
        switch settings.backend {
        case .claudeCLI:        canSendImages = false   // `claude -p` takes stdin text only
        case .anthropicAPI:     canSendImages = true
        case .openAICompatible: canSendImages = settings.providerSupportsVision
        }

        let imageIDs = canSendImages
            ? PromptBuilder.selectImageCaptures(from: assets.captures, limit: 12)
            : []
        let combinedContext = [settings.recognitionScenario.analysisGuidance,
                               assets.workspace?.context ?? "",
                               assets.meetingContext,
                               "本次纪要附加要求：\(settings.minutesInstructions)"]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        let builder = PromptBuilder(assets: assets,
                                    contextHint: combinedContext,
                                    imageCaptureIDs: imageIDs)
        let timeline = builder.buildTimeline()

        let raw: String
        switch settings.backend {
        case .claudeCLI:
            progress("正在通过本机 Claude Code 生成纪要…")
            raw = try await runCLI(timeline: timeline)
        case .anthropicAPI:
            progress("正在调用 Anthropic API 生成纪要…")
            raw = try await runAPI(timeline: timeline, imageIDs: imageIDs)
        case .openAICompatible:
            let preset = settings.provider
            progress("正在调用 \(preset.name)（\(settings.providerModel)）生成纪要…")
            raw = try await runOpenAICompatible(timeline: timeline,
                                                imageIDs: imageIDs,
                                                progress: progress)
        }

        if let structured = Self.parseStructured(raw) {
            return Result(markdown: StructuredMinutesRenderer.markdown(from: structured),
                          structured: structured, usedFallback: false)
        }
        return Result(markdown: raw, structured: nil, usedFallback: true)
    }

    static func parseStructured(_ raw: String) -> StructuredMinutes? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            let lines = candidate.components(separatedBy: .newlines)
            candidate = lines.dropFirst().dropLast(lines.last?.hasPrefix("```") == true ? 1 : 0)
                .joined(separator: "\n")
        }
        if let first = candidate.firstIndex(of: "{"),
           let last = candidate.lastIndex(of: "}") {
            candidate = String(candidate[first...last])
        }
        guard let data = candidate.data(using: .utf8),
              let value = try? JSONDecoder().decode(StructuredMinutes.self, from: data),
              value.isMeaningful else { return nil }
        return value
    }

    // MARK: - OpenAI-compatible providers

    private func runOpenAICompatible(
        timeline: String,
        imageIDs: Set<Int>,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let client = OpenAICompatibleClient(
            baseURL: settings.providerBaseURL,
            apiKey: settings.providerKey,
            model: settings.providerModel,
            supportsVision: settings.providerSupportsVision
        )

        let attachments = assets.captures
            .filter { imageIDs.contains($0.id) }
            .compactMap { capture -> OpenAICompatibleClient.Attachment? in
                guard let jpeg = jpegData(from: capture.image) else { return nil }
                return .init(caption: "图片 #\(capture.id)（屏幕画面，时间 \(capture.timecode)）：",
                             jpeg: jpeg)
            }

        let materialAttachments = assets.materials.compactMap { material -> OpenAICompatibleClient.Attachment? in
            guard let jpeg = material.imageJPEG else { return nil }
            return .init(caption: "会议材料图片《\(material.name)》：", jpeg: jpeg)
        }

        return try await client.complete(
            system: PromptBuilder.systemPrompt,
            user: timeline,
            images: materialAttachments + attachments,
            onProgress: progress
        )
    }

    // MARK: - Local CLI

    /// The CLI is an agentic tool, not a plain inference endpoint — it can only
    /// take text on stdin. Screen captures therefore reach it as OCR text; the
    /// diagram images are dropped. That is the tradeoff for using this backend.
    private func runCLI(timeline: String) async throws -> String {
        let claude = try ToolLocator.require(.claude)
        let prompt = """
        \(PromptBuilder.systemPrompt)

        ---

        以下是会议材料，请按上述要求输出结构化 JSON。不要有任何前言、说明或追问。

        \(timeline)
        """

        let result = try await Shell.check(
            claude,
            ["-p", "--output-format", "text"],
            stdin: prompt,
            timeout: 900
        )
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyResponse }
        return text
    }

    // MARK: - Anthropic API

    private func runAPI(timeline: String, imageIDs: Set<Int>) async throws -> String {
        guard let key = settings.apiKey, !key.isEmpty else { throw ToolError.noAPIKey }

        var content: [[String: Any]] = []

        for material in assets.materials {
            guard let data = material.imageJPEG else { continue }
            content.append(["type": "text", "text": "会议材料图片《\(material.name)》："])
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg",
                           "data": data.base64EncodedString()],
            ])
        }

        // Diagrams first so the model has them in view while reading the timeline.
        for capture in assets.captures where imageIDs.contains(capture.id) {
            guard let data = jpegData(from: capture.image) else { continue }
            content.append([
                "type": "text",
                "text": "图片 #\(capture.id)（屏幕画面，时间 \(capture.timecode)）：",
            ])
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": data.base64EncodedString(),
                ],
            ])
        }

        content.append(["type": "text", "text": timeline])

        let body: [String: Any] = [
            "model": settings.apiModel,
            "max_tokens": 16000,
            "system": PromptBuilder.systemPrompt,
            "thinking": ["type": "adaptive"],
            "messages": [["role": "user", "content": content]],
            "stream": true,
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 900

        // Streaming keeps the connection alive on long generations, which a
        // 40-minute meeting with a dozen screenshots reliably is.
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var detail = ""
            for try await line in bytes.lines { detail += line }
            throw APIError.http(http.statusCode, detail)
        }

        var text = ""
        var refused = false

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            switch event["type"] as? String {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let chunk = delta["text"] as? String {
                    text += chunk
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["stop_reason"] as? String == "refusal" {
                    refused = true
                }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String
                throw APIError.stream(message ?? "未知的流式错误")
            default:
                break
            }
        }

        if refused, text.isEmpty { throw APIError.refused }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func jpegData(from image: CGImage, quality: CGFloat = 0.72) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    enum Failure: LocalizedError {
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "模型没有返回内容。可能是内容过长或被拒绝，可尝试关闭画面分析后重试。"
            }
        }
    }

    enum APIError: LocalizedError {
        case http(Int, String)
        case stream(String)
        case refused

        var errorDescription: String? {
            switch self {
            case .http(401, _):     return "API key 无效或已过期。"
            case .http(429, _):     return "触发速率限制，请稍后重试。"
            case .http(let code, let detail):
                return "API 返回 \(code)：\(detail.prefix(300))"
            case .stream(let message):
                return "生成中断：\(message)"
            case .refused:
                return "模型拒绝了本次请求。"
            }
        }
    }
}
