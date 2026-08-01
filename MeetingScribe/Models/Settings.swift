import Foundation
import Observation

enum BackendKind: String, CaseIterable, Identifiable, Codable {
    case claudeCLI
    case anthropicAPI
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCLI:         return "本机 Claude Code"
        case .anthropicAPI:      return "Anthropic API"
        case .openAICompatible:  return "其他大模型"
        }
    }

    var explanation: String {
        switch self {
        case .claudeCLI:
            return "调用本机已安装的 claude 命令，使用现有订阅，不额外计费。屏幕画面以文字形式传入，架构图等图片会被跳过。"
        case .anthropicAPI:
            return "直接调用 Anthropic API，需要 API key，按量计费。支持把架构图作为图片传入。"
        case .openAICompatible:
            return "DeepSeek、智谱、Kimi、通义、硅基流动，或任意 OpenAI 兼容接口（含本地 Ollama）。选了不支持读图的模型时，画面只以 OCR 文字传入。"
        }
    }
}

/// How densely to sample the screen for slides and documents.
enum FrameDensity: String, CaseIterable, Identifiable, Codable {
    case off, sparse, normal, dense

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:    return "不分析画面"
        case .sparse: return "稀疏"
        case .normal: return "标准"
        case .dense:  return "密集"
        }
    }

    /// Seconds between samples.
    var interval: TimeInterval {
        switch self {
        case .off:    return .infinity
        case .sparse: return 10
        case .normal: return 5
        case .dense:  return 3
        }
    }

    /// Hamming distance below which two frames count as the same content.
    /// A moving cursor shifts almost no bits; a slide change shifts many.
    var distinctness: Int {
        switch self {
        case .off:    return .max
        case .sparse: return 14
        case .normal: return 10
        case .dense:  return 7
        }
    }

    /// Ceiling so a jittery recording can't produce hundreds of images.
    var maxFrames: Int {
        switch self {
        case .off:    return 0
        case .sparse: return 40
        case .normal: return 80
        case .dense:  return 140
        }
    }
}

enum RecognitionScenario: String, CaseIterable, Identifiable, Codable {
    case mandarin
    case english
    case autoMultilingual
    case hongKongMixed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mandarin: return "普通话会议"
        case .english: return "英文会议"
        case .autoMultilingual: return "自动多语言"
        case .hongKongMixed: return "香港粤语 / 普通话 / 英语"
        }
    }

    var whisperLanguage: String {
        switch self {
        case .mandarin: return "zh"
        case .english: return "en"
        case .autoMultilingual, .hongKongMixed: return "auto"
        }
    }

    var transcriptionHint: String {
        switch self {
        case .hongKongMixed:
            return "香港商务会议，发言会混合香港粤语、普通话和英语。呢个 project 要同 client confirm，再 update timeline。"
        default:
            return ""
        }
    }

    var analysisGuidance: String {
        switch self {
        case .hongKongMixed:
            return "本次会议可能混合香港粤语、普通话和英语。理解粤语原意后，用简体书面中文生成纪要；产品名、公司名、缩写及常用英文业务术语保留英文原文。不要把粤语或英语音译成不通顺的普通话。"
        case .autoMultilingual:
            return "本次会议可能使用多种语言。纪要统一使用简体中文，专有名词和英文业务术语保留原文。"
        case .mandarin, .english:
            return ""
        }
    }
}

@Observable
final class Settings {
    static let shared = Settings()

    var backend: BackendKind {
        didSet { defaults.set(backend.rawValue, forKey: Keys.backend) }
    }
    var apiModel: String {
        didSet { defaults.set(apiModel, forKey: Keys.apiModel) }
    }
    var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }
    var recognitionScenario: RecognitionScenario {
        didSet {
            defaults.set(recognitionScenario.rawValue, forKey: Keys.recognitionScenario)
            language = recognitionScenario.whisperLanguage
        }
    }
    var frameDensity: FrameDensity {
        didSet { defaults.set(frameDensity.rawValue, forKey: Keys.frameDensity) }
    }
    var glossary: String {
        didSet { defaults.set(glossary, forKey: Keys.glossary) }
    }
    /// Background fed to the analysis prompt — team names, product names, what
    /// this meeting series is. Cheap to fill in, noticeably improves the summary.
    var contextHint: String {
        didSet { defaults.set(contextHint, forKey: Keys.contextHint) }
    }
    var keepIntermediates: Bool {
        didSet { defaults.set(keepIntermediates, forKey: Keys.keepIntermediates) }
    }

    /// Off by default: it roughly doubles processing time, and is only worth it
    /// when the summary needs to say who committed to what.
    var separateSpeakers: Bool {
        didSet { defaults.set(separateSpeakers, forKey: Keys.separateSpeakers) }
    }
    /// 0 lets clustering decide. On compressed conference audio an explicit
    /// headcount is markedly more reliable — automatic clustering over-splits.
    var expectedSpeakerCount: Int {
        didSet { defaults.set(expectedSpeakerCount, forKey: Keys.speakerCount) }
    }

    // MARK: OpenAI-compatible providers

    var providerID: String {
        didSet { defaults.set(providerID, forKey: Keys.providerID) }
    }
    /// Prefilled from the preset but editable — vendors move endpoints, and a
    /// wrong-but-fixable URL beats a hardcoded one the user can't correct.
    var providerBaseURL: String {
        didSet { defaults.set(providerBaseURL, forKey: Keys.providerBaseURL) }
    }
    var providerModel: String {
        didSet { defaults.set(providerModel, forKey: Keys.providerModel) }
    }
    /// Set when the user types a model the preset doesn't list.
    var providerVisionOverride: Bool? {
        didSet {
            if let value = providerVisionOverride {
                defaults.set(value, forKey: Keys.providerVision)
            } else {
                defaults.removeObject(forKey: Keys.providerVision)
            }
        }
    }

    var provider: ProviderPreset { ProviderPreset.preset(id: providerID) }

    /// Whether the currently selected model can accept images.
    var providerSupportsVision: Bool {
        if let override = providerVisionOverride { return override }
        return provider.models.first { $0.id == providerModel }?.supportsVision ?? false
    }

    /// Switching provider swaps in that vendor's defaults; the previous
    /// vendor's key stays in the keychain under its own account.
    func selectProvider(_ preset: ProviderPreset) {
        providerID = preset.id
        providerBaseURL = preset.baseURL
        providerModel = preset.models.first?.id ?? ""
        providerVisionOverride = nil
    }

    var providerKey: String? {
        get { Keychain.read(account: provider.keychainAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(account: provider.keychainAccount, value: newValue)
            } else {
                Keychain.delete(account: provider.keychainAccount)
            }
        }
    }

    private enum Keys {
        static let backend = "backend"
        static let apiModel = "apiModel"
        static let language = "language"
        static let recognitionScenario = "recognitionScenario"
        static let frameDensity = "frameDensity"
        static let glossary = "glossary"
        static let contextHint = "contextHint"
        static let keepIntermediates = "keepIntermediates"
        static let separateSpeakers = "separateSpeakers"
        static let speakerCount = "expectedSpeakerCount"
        static let providerID = "providerID"
        static let providerBaseURL = "providerBaseURL"
        static let providerModel = "providerModel"
        static let providerVision = "providerVisionOverride"
    }

    static let defaultGlossary = """
    # 领域词表 —— 作为语音识别的初始提示注入，纠正术语识别
    # 写成通顺的句子（不要散词罗列），170 字以内。发现新错词就补进来，越用越准。

    技术会议。术语：Agent、Syslog、SIEM、Hotfix、UAT、CVE、POC、Oracle、备机、\
    主备、拓扑图、日志、告警检出、可执行文件、脚本文件、文件落盘、内存违规访问、\
    反弹shell、异常登录、入侵检测、闭环、需求、哈希。
    """

    private let defaults = UserDefaults.standard

    private init() {
        backend = BackendKind(rawValue: defaults.string(forKey: Keys.backend) ?? "") ?? .claudeCLI
        apiModel = defaults.string(forKey: Keys.apiModel) ?? "claude-opus-5"
        let storedLanguage = defaults.string(forKey: Keys.language) ?? "zh"
        let migratedScenario: RecognitionScenario = switch storedLanguage {
        case "en": .english
        case "auto": .autoMultilingual
        default: .mandarin
        }
        let selectedScenario = RecognitionScenario(
            rawValue: defaults.string(forKey: Keys.recognitionScenario) ?? ""
        ) ?? migratedScenario
        recognitionScenario = selectedScenario
        language = selectedScenario.whisperLanguage
        frameDensity = FrameDensity(rawValue: defaults.string(forKey: Keys.frameDensity) ?? "") ?? .normal
        glossary = defaults.string(forKey: Keys.glossary) ?? Settings.defaultGlossary
        contextHint = defaults.string(forKey: Keys.contextHint) ?? ""
        keepIntermediates = defaults.object(forKey: Keys.keepIntermediates) as? Bool ?? false
        separateSpeakers = defaults.object(forKey: Keys.separateSpeakers) as? Bool ?? false
        expectedSpeakerCount = defaults.object(forKey: Keys.speakerCount) as? Int ?? 0

        let storedProvider = defaults.string(forKey: Keys.providerID) ?? ProviderPreset.deepseek.id
        providerID = storedProvider
        let preset = ProviderPreset.preset(id: storedProvider)
        providerBaseURL = defaults.string(forKey: Keys.providerBaseURL) ?? preset.baseURL
        providerModel = defaults.string(forKey: Keys.providerModel) ?? (preset.models.first?.id ?? "")
        providerVisionOverride = defaults.object(forKey: Keys.providerVision) as? Bool
    }

    /// Kept in the keychain, never in UserDefaults.
    var apiKey: String? {
        get { Keychain.read(account: "anthropic-api-key") }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(account: "anthropic-api-key", value: newValue)
            } else {
                Keychain.delete(account: "anthropic-api-key")
            }
        }
    }
}
