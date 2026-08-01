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

/// An OpenAI-compatible endpoint. Nearly every Chinese vendor offers one, so a
/// single client plus a table of presets covers them all — including local
/// runtimes like Ollama and LM Studio.
struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let models: [ModelOption]
    let docsURL: String
    let keyHint: String
    /// Some vendors need no key (local runtimes).
    var requiresKey: Bool = true

    var keychainAccount: String { "provider-key-\(id)" }

    static let all: [ProviderPreset] = [openAI, deepseek, zhipu, moonshot, qwen, siliconflow, ollama, custom]

    static func preset(id: String) -> ProviderPreset {
        all.first { $0.id == id } ?? deepseek
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

    static let deepseek = ProviderPreset(
        id: "deepseek",
        name: "DeepSeek",
        baseURL: "https://api.deepseek.com/v1",
        models: [
            ModelOption(id: "deepseek-chat", label: "deepseek-chat（通用）", supportsVision: false),
            ModelOption(id: "deepseek-reasoner", label: "deepseek-reasoner（推理，更慢）", supportsVision: false),
        ],
        docsURL: "https://platform.deepseek.com/api_keys",
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

    static let moonshot = ProviderPreset(
        id: "moonshot",
        name: "Kimi 月之暗面",
        baseURL: "https://api.moonshot.cn/v1",
        models: [
            ModelOption(id: "moonshot-v1-128k", label: "moonshot-v1-128k（长上下文）", supportsVision: false),
            ModelOption(id: "moonshot-v1-32k", label: "moonshot-v1-32k", supportsVision: false),
        ],
        docsURL: "https://platform.moonshot.cn/console/api-keys",
        keyHint: "sk-…"
    )

    static let qwen = ProviderPreset(
        id: "qwen",
        name: "通义千问",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        models: [
            ModelOption(id: "qwen-max", label: "qwen-max（最强）", supportsVision: false),
            ModelOption(id: "qwen-plus", label: "qwen-plus（均衡）", supportsVision: false),
            ModelOption(id: "qwen-vl-max", label: "qwen-vl-max（支持读图）", supportsVision: true),
        ],
        docsURL: "https://bailian.console.aliyun.com/?apiKey=1",
        keyHint: "sk-…"
    )

    static let siliconflow = ProviderPreset(
        id: "siliconflow",
        name: "硅基流动",
        baseURL: "https://api.siliconflow.cn/v1",
        models: [
            ModelOption(id: "deepseek-ai/DeepSeek-V3", label: "DeepSeek-V3", supportsVision: false),
            ModelOption(id: "Qwen/Qwen2.5-72B-Instruct", label: "Qwen2.5-72B", supportsVision: false),
        ],
        docsURL: "https://cloud.siliconflow.cn/account/ak",
        keyHint: "sk-…"
    )

    static let ollama = ProviderPreset(
        id: "ollama",
        name: "本地 Ollama",
        baseURL: "http://localhost:11434/v1",
        models: [
            ModelOption(id: "qwen2.5:32b", label: "qwen2.5:32b", supportsVision: false),
            ModelOption(id: "llama3.1:70b", label: "llama3.1:70b", supportsVision: false),
        ],
        docsURL: "https://ollama.com/library",
        keyHint: "（本地无需 key）",
        requiresKey: false
    )

    static let custom = ProviderPreset(
        id: "custom",
        name: "自定义（任意 OpenAI 兼容接口）",
        baseURL: "",
        models: [],
        docsURL: "",
        keyHint: "按服务商要求填写"
    )
}
