import Foundation
import Observation

enum BackendKind: String, CaseIterable, Identifiable, Codable {
    case codexCLI
    case claudeCLI
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codexCLI:          return "本机 Codex CLI"
        case .claudeCLI:         return "本机 Claude Code"
        case .openAICompatible:  return "API（OpenAI / 智谱）"
        }
    }

    var explanation: String {
        switch self {
        case .codexCLI:
            return "调用本机已登录的 codex 命令，使用现有订阅。任务以临时、只读模式运行，不保留 Codex 会话；画面以 OCR 文字传入。"
        case .claudeCLI:
            return "调用本机已安装的 claude 命令，使用现有订阅，不额外计费。屏幕画面以文字形式传入，架构图等图片会被跳过。"
        case .openAICompatible:
            return "调用已经验证过的 OpenAI API 或智谱 GLM，需要对应 API key。支持视觉的模型会直接接收筛选后的会议画面。"
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

    var explanation: String {
        switch self {
        case .mandarin: return "适合主要使用普通话的会议，能减少语言误判。"
        case .english: return "适合主要使用英语的会议，逐字稿保留英文。"
        case .autoMultilingual: return "不预设单一语言，适合语言无法提前确定的会议。"
        case .hongKongMixed: return "自动识别香港粤语、普通话及句中英语；纪要转换为简体书面中文并保留英文术语。"
        }
    }
}

@Observable
final class Settings {
    static let shared = Settings()

    var backend: BackendKind {
        didSet { defaults.set(backend.rawValue, forKey: Keys.backend) }
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
    var minutesInstructions: String {
        didSet { defaults.set(minutesInstructions, forKey: Keys.minutesInstructions) }
    }
    var keepIntermediates: Bool {
        didSet { defaults.set(keepIntermediates, forKey: Keys.keepIntermediates) }
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
    var providerKeyExists: Bool { Keychain.exists(account: provider.keychainAccount) }

    private enum Keys {
        static let backend = "backend"
        static let frameDensity = "frameDensity"
        static let glossary = "glossary"
        static let contextHint = "contextHint"
        static let minutesInstructions = "minutesInstructions"
        static let keepIntermediates = "keepIntermediates"
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

    static let defaultMinutesInstructions = """
    使用简体中文输出；优先保留问题、需求、决定、责任人、截止时间和协作约定。
    不确定的信息明确标注待核对，不要补充会议中没有出现的结论。
    """

    private let defaults = UserDefaults.standard

    private init() {
        // Keep the supported local CLIs; removed legacy backends migrate to API.
        let storedBackend = BackendKind(rawValue: defaults.string(forKey: Keys.backend) ?? "")
        backend = switch storedBackend {
        case .codexCLI: .codexCLI
        case .claudeCLI: .claudeCLI
        default: .openAICompatible
        }
        frameDensity = FrameDensity(rawValue: defaults.string(forKey: Keys.frameDensity) ?? "") ?? .normal
        glossary = defaults.string(forKey: Keys.glossary) ?? Settings.defaultGlossary
        contextHint = defaults.string(forKey: Keys.contextHint) ?? ""
        minutesInstructions = defaults.string(forKey: Keys.minutesInstructions)
            ?? Settings.defaultMinutesInstructions
        keepIntermediates = defaults.object(forKey: Keys.keepIntermediates) as? Bool ?? false
        let storedProvider = defaults.string(forKey: Keys.providerID) ?? ProviderPreset.openAI.id
        let preset = ProviderPreset.preset(id: storedProvider)
        let providerWasRemoved = !ProviderPreset.all.contains { $0.id == storedProvider }
        providerID = preset.id
        providerBaseURL = providerWasRemoved
            ? preset.baseURL : (defaults.string(forKey: Keys.providerBaseURL) ?? preset.baseURL)
        providerModel = providerWasRemoved
            ? (preset.models.first?.id ?? "")
            : (defaults.string(forKey: Keys.providerModel) ?? (preset.models.first?.id ?? ""))
        providerVisionOverride = providerWasRemoved
            ? nil : defaults.object(forKey: Keys.providerVision) as? Bool
    }

}
