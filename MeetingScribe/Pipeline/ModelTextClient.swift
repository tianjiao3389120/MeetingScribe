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
                supportsVision: false,
                apiStyle: provider.apiStyle,
                httpHeaders: provider.httpHeaders))
        }
    }

    func complete(system: String, user: String,
                  timeout: TimeInterval = 900,
                  debug: PipelineDebugSession? = nil) async throws -> String {
        let activeDebug: PipelineDebugSession?
        if let debug { activeDebug = debug } else { activeDebug = await PipelineDebugSession.current() }
        await activeDebug?.writeLog("MODEL TEXT REQUEST", "system:\n\(system)\n\nuser:\n\(user)")
        _ = await activeDebug?.writeTextArtifact(system, name: "model-system.txt")
        _ = await activeDebug?.writeTextArtifact(user, name: "model-user.txt")
        let raw: String
        switch backend {
        case .codex(let executable):
            raw = try await Shell.check(
                executable, ToolLocator.codexExecArguments,
                stdin: Self.prompt(system: system, user: user), timeout: timeout).stdout
        case .claude(let executable):
            raw = try await Shell.check(
                executable, ["-p", "--output-format", "text"],
                stdin: Self.prompt(system: system, user: user), timeout: timeout).stdout
        case .api(let client):
            raw = try await client.complete(system: system, user: user, images: [])
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        await activeDebug?.writeLog("MODEL TEXT RESPONSE", text)
        _ = await activeDebug?.writeTextArtifact(text, name: "model-response.txt")
        guard !text.isEmpty else { throw Failure.emptyResponse }
        return text
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
