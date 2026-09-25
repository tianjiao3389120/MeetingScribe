import Foundation

/// One text-generation entry point for every feature outside the image-aware
/// minutes analyzer. Constructing it reads an API key at most once, while local
/// CLI backends never touch MeetingScribe's keychain entries.
struct ModelTextClient {
    private enum Backend {
        case codex(String)
        case claude(String)
        case api(OpenAICompatibleClient)
    }

    private let backend: Backend

    init(settings: Settings) throws {
        switch settings.backend {
        case .codexCLI:
            backend = .codex(try ToolLocator.require(.codex))
        case .claudeCLI:
            backend = .claude(try ToolLocator.require(.claude))
        case .openAICompatible:
            let provider = settings.provider
            let key = settings.providerKey
            if provider.requiresKey,
               key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw Failure.missingAPIKey(provider.name)
            }
            backend = .api(OpenAICompatibleClient(
                baseURL: settings.providerBaseURL,
                apiKey: key,
                model: settings.providerModel,
                supportsVision: settings.providerSupportsVision,
                apiStyle: provider.apiStyle,
                httpHeaders: provider.httpHeaders))
        }
    }

    func complete(system: String, user: String, images: [URL] = [],
                  timeout: TimeInterval = 900, promptID: String? = nil,
                  node: String = "模型调用", purpose: String = "文本生成",
                  source: String = "ModelTextClient") async throws -> String {
        let startedAt = Date()
        let estimatedInput = TokenEstimator.count(system + "\n" + user)
        let backendName: String
        let modelName: String
        switch backend {
        case .codex: backendName = "Codex CLI"; modelName = "Codex CLI"
        case .claude: backendName = "Claude CLI"; modelName = "Claude CLI"
        case .api(let client): backendName = "API"; modelName = client.model
        }
        let debug = PipelineDebugRegistry.active
        let promptHandle = promptID.map {
            debug?.promptStart(id: $0, node: node, engine: backendName, model: modelName,
                               purpose: purpose, source: source, system: system, user: user)
        } ?? nil
        do {
            let raw: String
            var actualInput: Int?
            var actualOutput: Int?
            switch backend {
            case .codex(let executable):
                let imageArguments = images.flatMap { ["--image", $0.path] }
                raw = try await Shell.check(
                    executable, Array(ToolLocator.codexExecArguments.dropLast())
                        + imageArguments + ["-"],
                    stdin: Self.prompt(system: system, user: user), timeout: timeout).stdout
            case .claude(let executable):
                raw = try await Shell.check(
                    executable, ["-p", "--output-format", "text"],
                    stdin: Self.prompt(system: system, user: user), timeout: timeout).stdout
            case .api(let client):
                let attachments = images.compactMap { url -> OpenAICompatibleClient.Attachment? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return .init(caption: "关键屏幕画面《\(url.lastPathComponent)》：", jpeg: data)
                }
                let result = try await client.completeDetailed(
                    system: system, user: user, images: attachments)
                raw = result.text; actualInput = result.inputTokens; actualOutput = result.outputTokens
            }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.emptyResponse }
            TokenUsageLedger.record(
                startedAt: startedAt, backend: backendName, model: modelName,
                inputTokens: actualInput ?? estimatedInput,
                outputTokens: actualOutput ?? TokenEstimator.count(text),
                isEstimated: actualInput == nil || actualOutput == nil, status: .succeeded)
            if let promptHandle { debug?.promptEnd(promptHandle, output: text) }
            return text
        } catch {
            TokenUsageLedger.record(
                startedAt: startedAt, backend: backendName, model: modelName,
                inputTokens: estimatedInput, outputTokens: 0, isEstimated: true,
                status: error is CancellationError ? .cancelled : .failed, error: error)
            if let promptHandle { debug?.promptEnd(promptHandle, output: "失败：\(error.localizedDescription)", status: "failed") }
            throw error
        }
    }

    private static func prompt(system: String, user: String) -> String {
        "\(system)\n\n---\n\n\(user)"
    }

    enum Failure: LocalizedError {
        case missingAPIKey(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let provider): return "尚未配置 \(provider) API key。"
            case .emptyResponse: return "模型没有返回内容。"
            }
        }
    }
}
