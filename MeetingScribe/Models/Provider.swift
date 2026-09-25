import Foundation

/// A model the user can pick, plus what it can actually accept.
///
/// `supportsVision` matters: the pipeline sends architecture diagrams as
/// images. A text-only model must get OCR text instead, and the UI should say
/// so rather than silently dropping the screenshots.
struct ModelOption: Identifiable, Hashable {
    let id: String
    let label: String
    let supportsVision: Bool
}

enum ProviderAPIStyle: Hashable {
    case chatCompletions
    case responses
}

/// A verified API provider exposed by MeetingScribe.
struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let models: [ModelOption]
    let docsURL: String
    let keyHint: String
    var apiStyle: ProviderAPIStyle = .chatCompletions
    var httpHeaders: [String: String] = [:]
    /// Some vendors need no key (local runtimes).
    var requiresKey: Bool = true

    var keychainAccount: String { "provider-key-\(id)" }

    static let all: [ProviderPreset] = [openAI, zhipu]

    static func preset(id: String) -> ProviderPreset {
        all.first { $0.id == id } ?? openAI
    }

    // MARK: Presets

    static let openAI = ProviderPreset(
        id: "openai",
        name: "OpenAI",
        baseURL: "https://api.openai.com/v1",
        models: [
            ModelOption(id: "gpt-5.6-terra", label: "GPT-5.6 Terra（均衡，推荐）", supportsVision: true),
            ModelOption(id: "gpt-5.6-sol", label: "GPT-5.6 Sol（质量优先）", supportsVision: true),
            ModelOption(id: "gpt-5.6-luna", label: "GPT-5.6 Luna（经济快速）", supportsVision: true),
        ],
        docsURL: "https://platform.openai.com/api-keys",
        keyHint: "sk-…"
    )

    static let zhipu = ProviderPreset(
        id: "zhipu",
        name: "智谱 GLM",
        baseURL: "https://open.bigmodel.cn/api/paas/v4",
        models: [
            ModelOption(id: "glm-4-plus", label: "glm-4-plus（通用）", supportsVision: false),
            ModelOption(id: "glm-4v-plus", label: "glm-4v-plus（支持读图）", supportsVision: true),
            ModelOption(id: "glm-4-flash", label: "glm-4-flash（快，便宜）", supportsVision: false),
        ],
        docsURL: "https://bigmodel.cn/usercenter/apikeys",
        keyHint: "your-api-key"
    )

}
