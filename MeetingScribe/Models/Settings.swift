import Foundation
import Observation

enum BackendKind: String, CaseIterable, Identifiable, Codable {
    case claudeCLI
    case anthropicAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCLI:    return "本机 Claude Code"
        case .anthropicAPI: return "Anthropic API"
        }
    }

    var explanation: String {
        switch self {
        case .claudeCLI:
            return "调用本机已安装的 claude 命令，使用现有订阅，不额外计费。屏幕画面以文字形式传入，架构图等图片会被跳过。"
        case .anthropicAPI:
            return "直接调用 Anthropic API，需要 API key，按量计费。支持把架构图作为图片传入，纪要质量更好。"
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

    private enum Keys {
        static let backend = "backend"
        static let apiModel = "apiModel"
        static let language = "language"
        static let frameDensity = "frameDensity"
        static let glossary = "glossary"
        static let contextHint = "contextHint"
        static let keepIntermediates = "keepIntermediates"
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
        language = defaults.string(forKey: Keys.language) ?? "zh"
        frameDensity = FrameDensity(rawValue: defaults.string(forKey: Keys.frameDensity) ?? "") ?? .normal
        glossary = defaults.string(forKey: Keys.glossary) ?? Settings.defaultGlossary
        contextHint = defaults.string(forKey: Keys.contextHint) ?? ""
        keepIntermediates = defaults.object(forKey: Keys.keepIntermediates) as? Bool ?? false
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
