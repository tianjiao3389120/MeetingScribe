import AppKit
import Foundation
import Observation
import SwiftUI

struct RealtimeTranscriptionView: View {
    @State private var model = RealtimeTranscriptionViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时字幕")
                        .font(.title2.weight(.semibold))
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(model.error == nil ? Color.secondary : Color.red)
                }
                Spacer()
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

            Divider()

            HStack(spacing: 16) {
                Picker("识别场景", selection: $model.scenario) {
                    ForEach(RecognitionScenario.allCases) { scenario in
                        Text(scenario.displayName).tag(scenario)
                    }
                }
                .frame(maxWidth: 330)
                Toggle("简体中文翻译", isOn: $model.translationEnabled)
                    .toggleStyle(.switch)
                Spacer()
                Text("翻译使用“设置 → 大模型”中的当前服务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.isRunning)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

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
                                ForEach(model.lines) { line in
                                    subtitleRow(line)
                                }
                            }
                            if !model.partialText.isEmpty {
                                Text(model.partialText)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
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

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            HStack {
                Text("\(model.outputDescription) · 已发送 \(ByteCountFormatter.string(fromByteCount: Int64(model.sentBytes), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
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
        .frame(minWidth: 680, minHeight: 520)
        .onDisappear { model.stop() }
    }

    private func subtitleRow(_ line: RealtimeSubtitleLine) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(line.original)
                .font(.body)
                .textSelection(.enabled)
            if model.translationEnabled {
                if let translation = line.translation {
                    Text(translation)
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                        .textSelection(.enabled)
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
        .id(line.id)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Divider() }
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
    var translationEnabled = true
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

    var finalText: String { RealtimeSubtitleTranslator.originalText(from: lines) }
    var translatedText: String { RealtimeSubtitleTranslator.translatedText(from: lines) }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        error = nil
        needsAudioPermissionHelp = false
        partialText = ""
        lines = []
        sentBytes = 0
        serverEventCount = 0
        transcriptEventCount = 0
        status = "正在连接…"
        Task { await run() }
    }

    func stop() {
        guard isRunning else { return }
        status = "正在保存…"
        capture?.stop()
        let sender = senderTask
        let receiver = receiverTask
        let realtime = realtime
        let outputURL = outputURL
        Task {
            await sender?.value
            if let capture, let outputURL { capture.copyWAV(to: outputURL) }
            try? await realtime?.commit()
            try? await Task.sleep(for: .seconds(2))
            receiver?.cancel()
            realtime?.close()
            _ = await receiver?.value
            if let outputURL {
                persistTranscripts(outputURL: outputURL)
            }
            isRunning = false
            status = "已停止"
            capture = nil
            self.realtime = nil
            senderTask = nil
            receiverTask = nil
        }
    }

    private func run() async {
        do {
            let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
                ?? (Settings.shared.providerID == "openai" ? Settings.shared.providerKey : nil)
            guard let key, !key.isEmpty else {
                throw OpenAIRealtimeTranscriptionService.Failure.missingAPIKey
            }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MeetingScribe/realtime", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent("realtime-\(Int(Date().timeIntervalSince1970)).wav")
            let capture = BlackHoleAudioSocketClient(outputURL: output)
            let language: String? = switch scenario {
            case .mandarin: "zh"
            case .english: "en"
            case .autoMultilingual, .hongKongMixed: nil
            }
            let prompt = [scenario.transcriptionHint, Transcriber.trimGlossary(Settings.shared.glossary)]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let realtime = try OpenAIRealtimeTranscriptionService(
                apiKey: key, language: language, prompt: prompt)
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
                startTranslationIfNeeded()
            }
        case .failed(let message): error = message
        case .status(let value):
            if !value.isEmpty { status = value }
        }
    }

    private func setError(_ message: String) {
        error = message
        status = "连接中断"
    }

    private func startTranslationIfNeeded() {
        guard translationEnabled, translator != nil, translationTask == nil else { return }
        translationTask = Task { [weak self] in
            await self?.translatePendingLines()
        }
    }

    private func translatePendingLines() async {
        while let index = lines.firstIndex(where: {
            $0.translation == nil && $0.translationError == nil
        }), let translator {
            let id = lines[index].id
            let original = lines[index].original
            do {
                let translated = try await translator.translate(original)
                if let current = lines.firstIndex(where: { $0.id == id }) {
                    lines[current].translation = translated
                }
            } catch {
                if let current = lines.firstIndex(where: { $0.id == id }) {
                    lines[current].translationError = error.localizedDescription
                }
            }
            if let outputURL { persistTranscripts(outputURL: outputURL) }
        }
        translationTask = nil
    }

    private func persistTranscripts(outputURL: URL) {
        let originalURL = outputURL.deletingPathExtension().appendingPathExtension("txt")
        try? finalText.write(to: originalURL, atomically: true, encoding: .utf8)
        var names = [originalURL.lastPathComponent, outputURL.lastPathComponent]
        if translationEnabled, !translatedText.isEmpty {
            let translatedURL = outputURL.deletingPathExtension()
                .appendingPathExtension("translated.txt")
            try? translatedText.write(to: translatedURL, atomically: true, encoding: .utf8)
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
