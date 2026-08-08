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
            level: ToolLocator.path(for: .whisper) == nil ? .failed : .ready))

        let modelsReady = ToolLocator.modelPath() != nil && ToolLocator.vadModelPath() != nil
        results.append(.init(
            id: "models",
            title: "离线识别模型",
            detail: modelsReady ? "Whisper 与 VAD 模型均已就绪" : "模型不完整，请在设置的“转录”中下载",
            level: modelsReady ? .ready : .failed))

        let blackHoleReady = BlackHoleAudioCaptureService.inputDeviceAvailable()
        results.append(.init(
            id: "blackhole",
            title: "系统音频设备",
            detail: blackHoleReady ? "已找到 BlackHole 2ch" : "未找到 BlackHole 2ch；实时字幕无法采集电脑声音",
            level: blackHoleReady ? .ready : .failed))

        let helper = BlackHoleAudioSocketClient.resolvedHelperURL
        results.append(.init(
            id: "helper",
            title: "Audio Helper",
            detail: helper?.path ?? "未找到，请使用 ./build.sh --install 安装完整应用",
            level: helper == nil ? .failed : .ready))

        let openAIKeyExists = settings.realtimeOpenAIKeyExists
        let realtimeReady = openAIKeyExists
        let realtimeDetail: String
        if !openAIKeyExists {
            realtimeDetail = "尚未配置独立的 OpenAI Realtime API key"
        } else {
            realtimeDetail = "独立 OpenAI Realtime 配置已就绪"
        }
        results.append(.init(
            id: "realtime",
            title: "实时字幕服务",
            detail: realtimeDetail,
            level: realtimeReady ? .ready : .failed))

        let provider = settings.provider
        let endpointValid = validEndpoint(settings.providerBaseURL)
        let providerKeyReady = !provider.requiresKey || settings.providerKeyExists
        let translationReady = endpointValid && providerKeyReady && !settings.providerModel.isEmpty
        results.append(.init(
            id: "translation",
            title: "字幕翻译与会议纪要",
            detail: translationDetail(settings: settings, endpointValid: endpointValid,
                                      keyReady: providerKeyReady),
            level: translationReady ? .ready : .failed))

        let diarization = Diarizer.readiness()
        results.append(.init(
            id: "diarization",
            title: "说话人分离（可选）",
            detail: diarization.isReady ? "已安装并可用" : "未完整安装；关闭说话人分离时不影响其他功能",
            level: diarization.isReady ? .ready : .warning))

        results.append(.init(
            id: "permission",
            title: "Audio Helper 录音权限",
            detail: "macOS 不允许主程序代查另一个 App 的授权状态；开始实时字幕时会由 Helper 实际验证",
            level: .warning))
        return results
    }

    private static func validEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              url.host != nil else { return false }
        return scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host))
    }

    private static func translationDetail(settings: Settings, endpointValid: Bool,
                                          keyReady: Bool) -> String {
        if !endpointValid { return "大模型接口地址无效，远程服务必须使用 HTTPS" }
        if !keyReady { return "尚未配置 \(settings.provider.name) API key" }
        if settings.providerModel.isEmpty { return "尚未选择或填写模型" }
        return "\(settings.provider.name) · \(settings.providerModel)"
    }
}
