import AppKit
import Foundation
import Observation
import SwiftUI

struct RealtimeTranscriptionView: View {
    private enum DisplayMode: String, CaseIterable, Identifiable {
        case bilingual = "原文 + 翻译"
        case original = "仅原文"
        case translation = "仅翻译"

        var id: String { rawValue }
    }

    @State private var model = RealtimeTranscriptionViewModel()
    @State private var showDiagnostics = false
    @State private var showHistory = false
    @State private var focusMode = false
    @State private var displayMode: DisplayMode = .bilingual
    @State private var backgroundOpacity = 0.92
    @State private var subtitleOpacity = 1.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if !focusMode {
                standardHeader
                Divider()
                controls
                Divider()
            }

            subtitleContent

            if !focusMode {
                statusFooter
            }
        }
        .frame(minWidth: focusMode ? 420 : 680, minHeight: focusMode ? 220 : 520)
        .background(Color(nsColor: .windowBackgroundColor).opacity(backgroundOpacity))
        .background(FloatingWindowConfigurator())
        .overlay(alignment: .topTrailing) {
            if focusMode {
                Button("退出专注字幕", systemImage: "rectangle.compress.vertical") {
                    focusMode = false
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .help("恢复完整控制界面")
                .padding(8)
                .opacity(0.65)
            }
        }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showDiagnostics) { RuntimeDiagnosticsView() }
        .sheet(isPresented: $showHistory) { RealtimeTranscriptHistoryView() }
    }

    private var standardHeader: some View {
        HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时字幕")
                        .font(.title2.weight(.semibold))
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(model.error == nil ? Color.secondary : Color.red)
                }
                Spacer()
                Button("专注字幕", systemImage: "rectangle.expand.vertical") { focusMode = true }
                Button("历史", systemImage: "clock.arrow.circlepath") { showHistory = true }
                Button("诊断", systemImage: "stethoscope") { showDiagnostics = true }
                if model.isRunning {
                    Button("停止", systemImage: "stop.fill", role: .destructive) {
                        model.stop()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("开始", systemImage: "record.circle.fill") {
                        model.start()
                    }
                    .buttonStyle(.borderedProminent)
                }
        }
        .padding(20)
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 16) {
                Picker("识别场景", selection: $model.scenario) {
                    ForEach(RecognitionScenario.allCases) { scenario in
                        Text(scenario.displayName).tag(scenario)
                    }
                }
                .frame(maxWidth: 330)
                .disabled(model.isRunning)
                Picker("识别质量", selection: $model.quality) {
                    ForEach(RealtimeTranscriptionQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .frame(width: 150)
                .disabled(model.isRunning)
                Toggle("简体中文翻译", isOn: $model.translationEnabled)
                    .toggleStyle(.switch)
                    .disabled(model.isRunning)
                Picker("显示", selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .frame(width: 150)
                .disabled(!model.translationEnabled)
                .onChange(of: model.translationEnabled) { _, enabled in
                    if !enabled, displayMode == .translation { displayMode = .original }
                }
                Spacer()
                Button("小") { model.subtitleSize = max(13, model.subtitleSize - 2) }
                    .help("减小字幕")
                Button("大") { model.subtitleSize = min(30, model.subtitleSize + 2) }
                    .help("增大字幕")
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("背景").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $backgroundOpacity, in: 0.15...1).frame(width: 80)
                    }
                    HStack(spacing: 5) {
                        Text("字幕").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $subtitleOpacity, in: 0.35...1).frame(width: 80)
                    }
                }
            }
            HStack {
                TextField("本场识别提示：客户、人名、产品名、英文缩写和会议主题",
                          text: $model.sessionHint)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isRunning)
                    .onChange(of: model.sessionHint) { _, value in
                        if value.count > 500 { model.sessionHint = String(value.prefix(500)) }
                    }
                Text("\(model.sessionHint.count)/500")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)

    }

    @ViewBuilder
    private var subtitleContent: some View {
        VStack(spacing: 0) {
            if model.needsAudioPermissionHelp {
                VStack(alignment: .leading, spacing: 10) {
                    Label("需要给 MeetingScribe Audio Helper 录音权限",
                          systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.callout.weight(.semibold))
                    Text("实时字幕由独立的 MeetingScribeAudioHelper.app 采集 BlackHole 系统音频。请在系统设置中允许该 Helper，而不是只允许主程序，然后返回这里重新开始。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("打开录音权限设置", systemImage: "gear") {
                            model.openAudioPrivacySettings()
                        }
                        Button("在 Finder 中显示 Helper", systemImage: "finder") {
                            model.revealAudioHelper()
                        }
                        .disabled(!model.helperAvailable)
                    }
                    Text(model.helperDescription)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .padding(14)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.lines.isEmpty && model.partialText.isEmpty {
                            ContentUnavailableView(
                                "等待语音",
                                systemImage: "waveform",
                                description: Text("开始后播放腾讯会议声音")
                            )
                            .frame(maxWidth: .infinity, minHeight: 260)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(visibleLines) { line in
                                    subtitleRow(line)
                                }
                            }
                            if displayMode != .translation, !model.partialText.isEmpty {
                                Text(model.partialText)
                                    .font(.system(size: model.subtitleSize))
                                    .foregroundStyle(.secondary)
                                    .opacity(subtitleOpacity)
                                    .textSelection(.enabled)
                                    .id("partial")
                            }
                            if displayMode == .translation, model.pendingTranslationCount > 0 {
                                HStack(spacing: 7) {
                                    ProgressView().controlSize(.small)
                                    Text("正在结合上下文翻译…")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                                .id("partial")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .onChange(of: model.partialText) { _, _ in
                    withAnimation { proxy.scrollTo("partial", anchor: .bottom) }
                }
                .onChange(of: model.lines.count) { _, _ in
                    if let id = model.lines.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private var statusFooter: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            HStack {
                Text("\(model.outputDescription) · 已发送 \(ByteCountFormatter.string(fromByteCount: Int64(model.sentBytes), countStyle: .file)) · 待翻译 \(model.pendingTranslationCount) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("复制全部", systemImage: "doc.on.doc") { model.copyAll() }
                    .disabled(model.lines.isEmpty)
                Button("清空") { model.clearSubtitles() }
                    .disabled(model.lines.isEmpty && model.partialText.isEmpty)
                Button("关闭") { dismiss() }
                    .disabled(model.isRunning)
            }
            .padding(14)

            HStack(spacing: 8) {
                Text("音频电平")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ProgressView(value: Double(model.audioPeak), total: 1)
                    .tint(model.audioPeak > 0.02 ? .green : .secondary)
                    .frame(width: 120)
                Text(String(format: "%.1f%%", model.audioPeak * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)

            Text("服务端事件：\(model.serverEventCount) · 字幕事件：\(model.transcriptEventCount)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
            Text(model.captureDescription)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
            Text(model.helperDescription)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
    }

    private func subtitleRow(_ line: RealtimeSubtitleLine) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if displayMode != .translation {
                Text(line.original)
                    .font(.system(size: model.subtitleSize))
                    .textSelection(.enabled)
            }
            if model.translationEnabled, displayMode != .original {
                if let translation = line.translation {
                    if !translation.isEmpty {
                        Text(translation)
                            .font(.system(size: model.subtitleSize))
                            .foregroundStyle(Color.accentColor)
                            .textSelection(.enabled)
                    }
                } else if let error = line.translationError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("翻译中…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(subtitleOpacity)
        .id(line.id)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var visibleLines: [RealtimeSubtitleLine] {
        guard displayMode == .translation else { return model.displayLines }
        return model.displayLines.filter {
            if let translation = $0.translation { return !translation.isEmpty }
            return $0.translationError != nil
        }
    }
}

@MainActor
@Observable
private final class RealtimeTranscriptionViewModel {
    var isRunning = false
    var status = "未开始"
    var partialText = ""
    var lines: [RealtimeSubtitleLine] = []
    var scenario = Settings.shared.recognitionScenario
    var quality = Settings.shared.realtimeTranscriptionQuality {
        didSet { Settings.shared.realtimeTranscriptionQuality = quality }
    }
    var sessionHint = ""
    var translationEnabled = true
    var subtitleSize: CGFloat = 17
    var sentBytes = 0
    var audioPeak: Float = 0
    var captureDescription = "采集设备：未启动"
    var serverEventCount = 0
    var transcriptEventCount = 0
    var error: String?
    var needsAudioPermissionHelp = false
    var outputDescription = "字幕和 WAV 将保存到 MeetingScribe/realtime"

    var helperAvailable: Bool { BlackHoleAudioSocketClient.resolvedHelperURL != nil }
    var helperDescription: String {
        if let url = BlackHoleAudioSocketClient.resolvedHelperURL {
            return "音频 Helper：\(url.path)"
        }
        return "音频 Helper：未找到，请使用 ./build.sh --install 安装完整应用"
    }

    private var capture: BlackHoleAudioSocketClient?
    private var realtime: OpenAIRealtimeTranscriptionService?
    private var senderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var translator: RealtimeSubtitleTranslator?
    private var outputURL: URL?
    private var isStopping = false
    private var displayStartIndex = 0

    var finalText: String { RealtimeSubtitleTranslator.originalText(from: lines) }
    var translatedText: String { RealtimeSubtitleTranslator.translatedText(from: lines) }
    var displayLines: [RealtimeSubtitleLine] {
        guard displayStartIndex < lines.count else { return [] }
        return Array(lines.dropFirst(displayStartIndex))
    }
    var pendingTranslationCount: Int {
        guard translationEnabled else { return 0 }
        return lines.filter { $0.translation == nil && $0.translationError == nil }.count
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isStopping = false
        error = nil
        needsAudioPermissionHelp = false
        partialText = ""
        lines = []
        displayStartIndex = 0
        sentBytes = 0
        serverEventCount = 0
        transcriptEventCount = 0
        status = "正在连接…"
        Task { await run() }
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        status = "正在保存…"
        capture?.stop()
        let sender = senderTask
        let receiver = receiverTask
        let realtime = realtime
        let outputURL = outputURL
        Task {
            await sender?.value
            if let capture, let outputURL { capture.copyWAV(to: outputURL) }
            try? await realtime?.finishAudio()
            try? await Task.sleep(for: .seconds(2))
            receiver?.cancel()
            realtime?.close()
            _ = await receiver?.value
            var translationFinished = true
            if let translationTask {
                status = "正在完成剩余翻译…"
                let timeout = Task {
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled else { return }
                    translationTask.cancel()
                }
                await translationTask.value
                timeout.cancel()
                translationFinished = !translationTask.isCancelled
            }
            if let outputURL {
                persistTranscripts(outputURL: outputURL)
            }
            isRunning = false
            isStopping = false
            status = translationFinished ? "已停止" : "已停止（部分译文未完成）"
            capture = nil
            self.realtime = nil
            senderTask = nil
            receiverTask = nil
            translationTask = nil
        }
    }

    private func run() async {
        do {
            let key = ProcessInfo.processInfo.environment["OPENAI_REALTIME_API_KEY"]
                ?? Settings.shared.realtimeOpenAIKey
            guard let key, !key.isEmpty else {
                throw OpenAIRealtimeTranscriptionService.Failure.missingAPIKey
            }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MeetingScribe/realtime", isDirectory: true)
            try RealtimeTranscriptStore.prepareDirectory(directory)
            let output = directory.appendingPathComponent("realtime-\(UUID().uuidString).wav")
            let capture = BlackHoleAudioSocketClient(outputURL: output)
            let language: String? = switch scenario {
            case .mandarin: "zh"
            case .english: "en"
            case .autoMultilingual, .hongKongMixed: nil
            }
            let prompt = [scenario.transcriptionHint,
                          Transcriber.trimGlossary(Settings.shared.glossary),
                          sessionHint.trimmingCharacters(in: .whitespacesAndNewlines)]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let realtime = try OpenAIRealtimeTranscriptionService(
                apiKey: key, model: quality.model, language: language, prompt: prompt)
            if translationEnabled {
                do {
                    translator = try RealtimeSubtitleTranslator(
                        settings: Settings.shared, scenario: scenario)
                } catch {
                    self.error = error.localizedDescription
                    translator = nil
                }
            } else {
                translator = nil
            }
            self.capture = capture
            self.realtime = realtime
            outputURL = output
            try await realtime.connect()
            status = "已连接，等待音频…"

            receiverTask = Task { @MainActor [weak self, realtime] in
                do {
                    while !Task.isCancelled {
                        let event = try await realtime.receive()
                        self?.handle(event)
                    }
                } catch {
                    if !Task.isCancelled { self?.setError(error.localizedDescription) }
                }
            }
            senderTask = Task { [capture, realtime] in
                do {
                    for await chunk in capture.pcmStream {
                        try await realtime.sendAudio(chunk)
                        await MainActor.run { [weak self, realtime] in
                            self?.sentBytes = realtime.sentBytes
                            self?.audioPeak = max(self?.audioPeak ?? 0, Self.peak(of: chunk))
                        }
                    }
                    await MainActor.run { [weak self] in
                        guard let self, self.isRunning, !self.isStopping else { return }
                        self.setError("Audio Helper 已停止发送音频。请运行环境诊断后重新开始。")
                    }
                } catch {
                    await MainActor.run { [weak self] in self?.setError(error.localizedDescription) }
                }
            }
            try await capture.start()
            captureDescription = "采集设备：\(capture.sourceDescription)"
            status = "采集中"
            while !Task.isCancelled, isRunning {
                try? await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            self.error = error.localizedDescription
            if let failure = error as? BlackHoleAudioSocketClient.Failure {
                needsAudioPermissionHelp = failure.needsPermissionHelp
            }
            status = "启动失败"
            isRunning = false
        }
    }

    private func handle(_ event: OpenAIRealtimeTranscriptionService.Event) {
        serverEventCount += 1
        switch event {
        case .delta(let text):
            if !text.isEmpty {
                transcriptEventCount += 1
                status = "收到实时字幕"
                partialText += text
            }
        case .completed(let text):
            if !text.isEmpty {
                transcriptEventCount += 1
                status = "已收到最终字幕"
                lines.append(RealtimeSubtitleLine(original: text))
                partialText = ""
                if let outputURL { persistTranscripts(outputURL: outputURL) }
                startTranslationIfNeeded()
            }
        case .failed(let message): error = message
        case .status(let value):
            if !value.isEmpty { status = value }
        }
    }

    private func setError(_ message: String) {
        guard isRunning else { return }
        error = message
        status = "连接中断"
        isStopping = true
        let capture = capture
        let outputURL = outputURL
        capture?.stop()
        senderTask?.cancel()
        receiverTask?.cancel()
        realtime?.close()
        isRunning = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if let capture, let outputURL {
                capture.copyWAV(to: outputURL)
                self?.persistTranscripts(outputURL: outputURL)
            }
            self?.capture = nil
            self?.realtime = nil
            self?.senderTask = nil
            self?.receiverTask = nil
            self?.isStopping = false
        }
    }

    private func startTranslationIfNeeded() {
        guard translationEnabled, translator != nil, translationTask == nil else { return }
        translationTask = Task { [weak self] in
            await self?.translatePendingLines()
        }
    }

    private func translatePendingLines() async {
        while translator != nil {
            // Let a few adjacent final segments accumulate. Translating them
            // together produces much more coherent pronouns and sentence
            // boundaries while original deltas continue to render instantly.
            do { try await Task.sleep(for: .seconds(2)) } catch { break }
            guard !Task.isCancelled else { break }
            let indexes = lines.indices.filter {
                lines[$0].translation == nil && lines[$0].translationError == nil
            }.prefix(3)
            guard !indexes.isEmpty, let translator else { break }
            let batch = Array(indexes)
            let ids = batch.map { lines[$0].id }
            let original = batch.map { lines[$0].original }.joined(separator: "\n")
            do {
                let translated = try await translator.translate(original)
                for id in ids.dropLast() {
                    if let current = lines.firstIndex(where: { $0.id == id }) {
                        lines[current].translation = ""
                    }
                }
                if let id = ids.last,
                   let current = lines.firstIndex(where: { $0.id == id }) {
                    lines[current].translation = translated
                }
            } catch {
                for id in ids {
                    if let current = lines.firstIndex(where: { $0.id == id }) {
                        lines[current].translationError = error.localizedDescription
                    }
                }
            }
            if let outputURL { persistTranscripts(outputURL: outputURL) }
        }
        translationTask = nil
    }

    private func persistTranscripts(outputURL: URL) {
        let originalURL = outputURL.deletingPathExtension().appendingPathExtension("txt")
        try? finalText.write(to: originalURL, atomically: true, encoding: .utf8)
        RealtimeTranscriptStore.secureFile(originalURL)
        RealtimeTranscriptStore.secureFile(outputURL)
        var names = [originalURL.lastPathComponent, outputURL.lastPathComponent]
        if translationEnabled, !translatedText.isEmpty {
            let translatedURL = outputURL.deletingPathExtension()
                .appendingPathExtension("translated.txt")
            try? translatedText.write(to: translatedURL, atomically: true, encoding: .utf8)
            RealtimeTranscriptStore.secureFile(translatedURL)
            names.insert(translatedURL.lastPathComponent, at: 1)
        }
        outputDescription = "已保存：" + names.joined(separator: "、")
    }

    func openAudioPrivacySettings() {
        NSWorkspace.shared.open(BlackHoleAudioSocketClient.audioPrivacySettingsURL)
    }

    func revealAudioHelper() {
        guard let url = BlackHoleAudioSocketClient.resolvedHelperURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyAll() {
        let text = translationEnabled && !translatedText.isEmpty
            ? lines.map { line in
                if let translation = line.translation { return "\(line.original)\n\(translation)" }
                return line.original
            }.joined(separator: "\n\n")
            : finalText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clearSubtitles() {
        displayStartIndex = lines.count
        partialText = ""
    }

    private static func peak(of data: Data) -> Float {
        var peak: Float = 0
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset + 1 < raw.count {
                let low = UInt16(raw.load(fromByteOffset: offset, as: UInt8.self))
                let high = UInt16(raw.load(fromByteOffset: offset + 1, as: UInt8.self)) << 8
                let sample = Int16(bitPattern: high | low)
                peak = max(peak, abs(Float(sample)) / Float(Int16.max))
                offset += 2
            }
        }
        return min(peak, 1)
    }

}

private struct FloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
    }
}
