import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var apiKey = Settings.shared.apiKey ?? ""
    @State private var modelStatus = ModelStatus.check()
    @State private var download: ModelDownloader?
    @State private var cacheSummary = SettingsView.describeCache()
    @State private var showVoiceProfiles = false
    @State private var voiceProfileCount = VoiceProfileStore.load().count

    static func describeCache() -> String {
        let (count, bytes) = TranscriptCache.summary
        let speakerCount = DiarizationCache.count
        guard count > 0 || speakerCount > 0 else { return "无" }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "转录 \(count) 份（\(size)），说话人 \(speakerCount) 份"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("生成纪要") {
                    Picker("后端", selection: $settings.backend) {
                        ForEach(BackendKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.radioGroup)

                    Text(settings.backend.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    switch settings.backend {
                    case .claudeCLI:
                        ToolRow(tool: .claude)
                    case .anthropicAPI:
                        SecureField("API key", text: $apiKey, prompt: Text("sk-ant-…"))
                            .onChange(of: apiKey) { _, new in settings.apiKey = new }
                        Picker("模型", selection: $settings.apiModel) {
                            Text("Claude Opus 5（最强）").tag("claude-opus-5")
                            Text("Claude Sonnet 5（更快更省）").tag("claude-sonnet-5")
                        }
                    case .openAICompatible:
                        ProviderSection(settings: $settings)
                    }
                }

                Section("转录") {
                    ToolRow(tool: .whisper)

                    LabeledContent("识别模型") {
                        switch modelStatus {
                        case .ready:
                            Label("已就绪", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .missing:
                            if let download, download.isDownloading {
                                VStack(alignment: .trailing, spacing: 4) {
                                    ProgressView(value: download.progress).frame(width: 160)
                                    Text(download.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Button("下载（约 1.5GB）") {
                                    let downloader = ModelDownloader()
                                    download = downloader
                                    Task {
                                        await downloader.run()
                                        modelStatus = ModelStatus.check()
                                    }
                                }
                            }
                        }
                    }

                    Picker("语言", selection: $settings.language) {
                        Text("中文").tag("zh")
                        Text("英文").tag("en")
                        Text("自动检测").tag("auto")
                    }
                }

                Section("说话人分离") {
                    SpeakerSection(settings: $settings)
                    LabeledContent("已登记声纹") {
                        HStack(spacing: 10) {
                            Text("\(voiceProfileCount) 人")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("管理…") { showVoiceProfiles = true }
                        }
                    }
                    Text("声纹只保存在本机应用支持目录，用于后续会议自动识别姓名，可随时删除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("画面分析") {
                    Picker("采样密度", selection: $settings.frameDensity) {
                        ForEach(FrameDensity.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text("屏幕共享的文档、告警列表、架构图是音频里没有的事实来源。相同画面会自动合并，只保留内容真正变化的那些。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("会议背景") {
                    TextEditor(text: $settings.contextHint)
                        .frame(height: 52)
                        .font(.callout)
                    Text("例如：与银行客户的双周例会，我方是安全产品厂商。填了能明显提升纪要质量。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("领域词表") {
                    TextEditor(text: $settings.glossary)
                        .frame(height: 110)
                        .font(.system(.caption, design: .monospaced))
                    HStack {
                        Text("写成通顺的句子而非散词罗列，170 字以内。发现新错词就补进来。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") { settings.glossary = Settings.defaultGlossary }
                            .buttonStyle(.link)
                    }
                }

                Section("缓存") {
                    LabeledContent("已缓存的转录结果") {
                        HStack(spacing: 10) {
                            Text(cacheSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("清除") {
                                TranscriptCache.clear()
                                DiarizationCache.clear()
                                cacheSummary = Self.describeCache()
                            }
                            .disabled(TranscriptCache.summary.count == 0 && DiarizationCache.count == 0)
                        }
                    }
                    Text("同一个文件重复处理时会复用转录和说话人结果。清除会同时删除两类缓存，不会删除已登记声纹。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("保留中间文件（音轨、截图）", isOn: $settings.keepIntermediates)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 640)
        .sheet(isPresented: $showVoiceProfiles, onDismiss: {
            voiceProfileCount = VoiceProfileStore.load().count
        }) {
            VoiceProfileManagementView()
        }
    }
}

/// Install, enable and tune speaker separation.
private struct SpeakerSection: View {
    @Binding var settings: Settings
    @State private var readiness = Diarizer.readiness()
    @State private var installing = false
    @State private var installDetail = ""
    @State private var installError: String?

    var body: some View {
        Toggle("为纪要区分说话人", isOn: $settings.separateSpeakers)
            .disabled(!readiness.isReady)

        Text("会额外增加约一倍处理时间（40 分钟会议约 4 分钟），换来纪要里「谁汇报、谁提要求、谁承诺」的归属信息。结果会缓存，重复处理同一文件不再重算。")
            .font(.caption)
            .foregroundStyle(.secondary)

        if settings.separateSpeakers, readiness.isReady {
            Picker("实际发言人数", selection: $settings.expectedSpeakerCount) {
                Text("不知道，自动判断").tag(0)
                ForEach(2...20, id: \.self) { Text("\($0) 人").tag($0) }
            }
            Text("只计算真正开口的人，不是参会名单人数。30 人参会但约 5 人发言，就填 5；无法判断时选自动。压缩音频下自动结果可能偏多，可在结果页调整后重新分离。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        switch readiness {
        case .ready:
            HStack {
                Label("已安装（\(ByteCountFormatter.string(fromByteCount: Diarizer.installedSize, countStyle: .file))）",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button("卸载") {
                    Diarizer.uninstall()
                    DiarizationCache.clear()
                    settings.separateSpeakers = false
                    readiness = Diarizer.readiness()
                }
                .font(.caption)
            }

        case .noPython:
            Label("需要 python3，可通过 brew install python 安装",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)

        case .needsRuntime, .needsModels:
            VStack(alignment: .leading, spacing: 6) {
                if installing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(installDetail).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button(readiness == .needsModels ? "下载模型（约 28MB）" : "安装（约 100MB）") {
                        install()
                    }
                    Text(readiness == .needsModels
                         ? "运行环境已就绪，还需下载声纹与分段模型。"
                         : "将在应用支持目录建立独立 Python 环境并下载模型，不影响系统 Python。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let installError {
                    Text(installError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func install() {
        installing = true
        installError = nil
        Task {
            do {
                if readiness == .needsRuntime {
                    try await Diarizer.installRuntime { detail in
                        Task { @MainActor in installDetail = detail }
                    }
                }
                try await Diarizer.downloadModels { detail in
                    Task { @MainActor in installDetail = detail }
                }
            } catch {
                installError = error.localizedDescription
            }
            installing = false
            readiness = Diarizer.readiness()
        }
    }
}

/// Provider picker for the OpenAI-compatible backend.
private struct ProviderSection: View {
    @Binding var settings: Settings
    @State private var key: String = ""
    @State private var customModel: String = ""
    @State private var probe: ProbeState = .idle

    private enum ProbeState: Equatable {
        case idle, running, ok(String), failed(String)
    }

    var body: some View {
        Picker("服务商", selection: Binding(
            get: { settings.providerID },
            set: { id in
                settings.selectProvider(ProviderPreset.preset(id: id))
                key = settings.providerKey ?? ""
                customModel = ""
                probe = .idle
            }
        )) {
            ForEach(ProviderPreset.all) { Text($0.name).tag($0.id) }
        }

        TextField("接口地址", text: $settings.providerBaseURL,
                  prompt: Text("https://api.example.com/v1"))
            .font(.system(.callout, design: .monospaced))

        if settings.provider.requiresKey {
            SecureField("API key", text: $key, prompt: Text(settings.provider.keyHint))
                .onChange(of: key) { _, new in settings.providerKey = new }
                .onAppear { key = settings.providerKey ?? "" }
        }

        if settings.provider.models.isEmpty {
            TextField("模型名", text: $settings.providerModel, prompt: Text("按服务商文档填写"))
                .font(.system(.callout, design: .monospaced))
            Toggle("该模型支持读图", isOn: Binding(
                get: { settings.providerVisionOverride ?? false },
                set: { settings.providerVisionOverride = $0 }
            ))
        } else {
            Picker("模型", selection: $settings.providerModel) {
                ForEach(settings.provider.models) { Text($0.label).tag($0.id) }
                if !customModel.isEmpty { Text(customModel).tag(customModel) }
            }
        }

        HStack {
            if settings.providerSupportsVision {
                Label("架构图等画面会作为图片传入", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("该模型不支持读图，画面只以 OCR 文字传入", systemImage: "text.alignleft")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !settings.provider.docsURL.isEmpty {
                Link("获取 key", destination: URL(string: settings.provider.docsURL)!)
                    .font(.caption)
            }
        }

        HStack(spacing: 10) {
            Button("测试连接") { runProbe() }
                .disabled(probe == .running || settings.providerBaseURL.isEmpty)

            switch probe {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small)
            case .ok(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(3).textSelection(.enabled)
            }
        }
    }

    /// One cheap round-trip, so a wrong URL or key surfaces here instead of
    /// after a three-minute transcription.
    private func runProbe() {
        probe = .running
        let client = OpenAICompatibleClient(
            baseURL: settings.providerBaseURL,
            apiKey: settings.providerKey,
            model: settings.providerModel,
            supportsVision: false
        )
        Task {
            do {
                let reply = try await client.complete(
                    system: "你是一个测试助手。", user: "回复两个字：可用", images: [])
                probe = .ok("连接正常：\(reply.prefix(20))")
            } catch {
                probe = .failed(error.localizedDescription)
            }
        }
    }
}

private struct ToolRow: View {
    let tool: ToolLocator.Tool

    var body: some View {
        LabeledContent(tool.displayName) {
            if let path = ToolLocator.path(for: tool) {
                Label(path, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Label("未安装", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(tool.installHint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private enum ModelStatus {
    case ready, missing

    static func check() -> ModelStatus {
        ToolLocator.modelPath() != nil ? .ready : .missing
    }
}

/// Downloads the whisper transcription and VAD models on demand.
@Observable
@MainActor
final class ModelDownloader {
    var isDownloading = false
    var progress: Double = 0
    var detail = ""

    func run() async {
        isDownloading = true
        defer { isDownloading = false }

        try? FileManager.default.createDirectory(at: ToolLocator.modelDirectory,
                                                 withIntermediateDirectories: true)

        // The transcription model is ~1.5GB and the VAD model under 1MB, so
        // treat the former as the whole progress bar.
        await fetch(ToolLocator.transcriptionModelURL,
                    to: ToolLocator.modelDirectory.appendingPathComponent(ToolLocator.transcriptionModel),
                    label: "识别模型")
        guard !failed else { return }

        detail = "下载 VAD 模型…"
        await fetch(ToolLocator.vadModelURL,
                    to: ToolLocator.modelDirectory.appendingPathComponent(ToolLocator.vadModel),
                    label: "VAD 模型", tracksProgress: false)
        guard !failed else { return }

        detail = "完成"
        progress = 1
    }

    private var failed = false

    /// Streams the body so the bar actually moves — `URLSession.download`
    /// reports nothing until it finishes, which on a 1.5GB file looks frozen.
    private func fetch(_ urlString: String,
                       to destination: URL,
                       label: String,
                       tracksProgress: Bool = true) async {
        guard !FileManager.default.fileExists(atPath: destination.path),
              let url = URL(string: urlString) else { return }

        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let expected = response.expectedContentLength   // -1 when unknown

            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            var written: Int64 = 0
            var lastReport = Date.distantPast

            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= (1 << 20) {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)

                    if tracksProgress, Date().timeIntervalSince(lastReport) > 0.2 {
                        lastReport = Date()
                        let mb = Double(written) / 1_048_576
                        if expected > 0 {
                            progress = Double(written) / Double(expected)
                            detail = String(format: "%@ %.0f / %.0f MB", label,
                                            mb, Double(expected) / 1_048_576)
                        } else {
                            detail = String(format: "%@ 已下载 %.0f MB", label, mb)
                        }
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
            try handle.close()

            // A truncated download is worse than none — whisper would fail with
            // an opaque error later instead of here.
            if expected > 0, written < expected {
                throw URLError(.dataLengthExceedsMaximum)
            }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            failed = true
            detail = "\(label)下载失败：\(error.localizedDescription)"
        }
    }
}
