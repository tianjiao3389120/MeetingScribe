import Foundation

struct RuntimeDiagnostic: Identifiable, Equatable {
    enum Level: Equatable {
        case ready, warning, failed

        var symbol: String {
            switch self {
            case .ready: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failed: "xmark.circle.fill"
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let level: Level
}

enum RuntimeDiagnostics {
    static func check(settings: Settings = .shared) -> [RuntimeDiagnostic] {
        var results: [RuntimeDiagnostic] = []

        results.append(.init(
            id: "whisper",
            title: "离线转录引擎",
            detail: ToolLocator.path(for: .whisper) ?? "未安装 whisper-cli（brew install whisper-cpp）",
            level: ToolLocator.path(for: .whisper) == nil ? .warning : .ready))

        let modelsReady = ToolLocator.modelPath() != nil && ToolLocator.vadModelPath() != nil
        results.append(.init(
            id: "models",
            title: "离线识别模型",
            detail: modelsReady ? "Whisper 与 VAD 模型均已就绪" : "模型不完整，请在设置的“转录”中下载",
            level: modelsReady ? .ready : .warning))

        let modelDiagnostic = modelDiagnostic(settings: settings)
        results.append(.init(
            id: "translation",
            title: "会议纪要模型",
            detail: modelDiagnostic.detail,
            level: modelDiagnostic.ready ? .ready : .failed))

        let diarization = Diarizer.readiness()
        results.append(.init(
            id: "diarization",
            title: "说话人分离（可选）",
            detail: diarization.isReady ? "已安装并可用" : "未完整安装；关闭说话人分离时不影响其他功能",
            level: diarization.isReady ? .ready : .warning))
        return results
    }

    private static func validEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              url.host != nil else { return false }
        return scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host))
    }

    private static func modelDiagnostic(settings: Settings) -> (ready: Bool, detail: String) {
        if settings.backend == .codexCLI {
            if let path = ToolLocator.path(for: .codex) {
                return (true, "本机 Codex CLI · \(path)（登录状态将在调用时验证）")
            }
            return (false, "未安装 Codex CLI；安装后请运行 codex login")
        }
        if settings.backend == .claudeCLI {
            if let path = ToolLocator.path(for: .claude) {
                return (true, "本机 Claude Code · \(path)（登录状态将在调用时验证）")
            }
            return (false, "未安装 Claude Code CLI")
        }

        let provider = settings.provider
        let endpointValid = validEndpoint(settings.providerBaseURL)
        let keyReady = !provider.requiresKey || settings.providerKeyExists
        let ready = endpointValid && keyReady && !settings.providerModel.isEmpty
        return (ready, translationDetail(settings: settings,
                                         endpointValid: endpointValid,
                                         keyReady: keyReady))
    }

    private static func translationDetail(settings: Settings, endpointValid: Bool,
                                          keyReady: Bool) -> String {
        if !endpointValid { return "大模型接口地址无效，远程服务必须使用 HTTPS" }
        if !keyReady { return "尚未配置 \(settings.provider.name) API key" }
        if settings.providerModel.isEmpty { return "尚未选择或填写模型" }
        return "\(settings.provider.name) · \(settings.providerModel)"
    }
}
