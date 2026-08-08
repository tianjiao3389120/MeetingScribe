import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var runner = PipelineRunner()
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var isTargeted = false
    @State private var savedPath: String?
    @State private var pendingMedia: URL?
    @State private var systemRecordingMonitor = SystemRecordingMonitor()
    @State private var interruptedJob: PendingMeetingJob?

    var body: some View {
        VStack(spacing: 0) {
            switch runner.stage {
            case .failed where runner.canRetryAnalysis:
                // Transcription succeeded; only the model call failed.
                RetryPanel(runner: runner, showSettings: $showSettings)
            case .idle, .failed:
                DropZone(isTargeted: $isTargeted,
                         error: runner.error,
                         recordingMonitor: systemRecordingMonitor,
                         onPick: { pendingMedia = $0 })
            case .done:
                ResultView(runner: runner, savedPath: $savedPath)
            default:
                ProgressPanel(runner: runner)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openWindow(id: "realtime-transcription") } label: {
                    Label("实时字幕", systemImage: "waveform.and.mic")
                }
                .disabled(runner.isRunning)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showHistory = true } label: {
                    Label("历史会议", systemImage: "clock.arrow.circlepath")
                }
                .disabled(runner.isRunning)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .disabled(runner.isRunning)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHistory) {
            MeetingHistoryView(onReprocess: { record in
                showHistory = false
                reprocess(record)
            }, onAnalyzeTranscript: { record, transcript in
                showHistory = false
                reprocess(record, editedTranscript: transcript)
            })
        }
        .sheet(isPresented: Binding(
            get: { pendingMedia != nil },
            set: { if !$0 { pendingMedia = nil } }
        )) {
            if let url = pendingMedia {
                MeetingPreparationView(mediaURL: url) { title, workspace, context, templateID, tags, materials in
                    pendingMedia = nil
                    runner.run(url: url, title: title, meetingContext: context,
                               minutesTemplateID: templateID,
                               workspace: workspace, tags: tags, materials: materials)
                } onCancel: {
                    pendingMedia = nil
                }
            }
        }
        .onAppear {
            if interruptedJob == nil { interruptedJob = PendingJobStore.load() }
        }
        .alert("发现未完成的会议处理", isPresented: Binding(
            get: { interruptedJob != nil },
            set: { if !$0 { interruptedJob = nil } }
        )) {
            Button("放弃", role: .destructive) {
                if let job = interruptedJob { PendingJobStore.clear(id: job.id) }
                interruptedJob = nil
            }
            Button("继续处理") {
                if let job = interruptedJob { resume(job) }
                interruptedJob = nil
            }
        } message: {
            Text("上次可能在转录或生成纪要期间退出。继续时会复用已经完成的转录缓存。")
        }
    }

    private func reprocess(_ record: MeetingRecord, editedTranscript: Transcript? = nil) {
        Task {
            let workspace = (try? MeetingWorkspaceStore.load())?
                .first { $0.id == record.workspaceID }
            var materials: [SupportingMaterial] = []
            for reference in record.materials ?? [] {
                let url = URL(fileURLWithPath: reference.sourcePath)
                if let value = try? await Task.detached(operation: {
                    try MaterialExtractor.extract(from: url)
                }).value { materials.append(value) }
            }
            if let editedTranscript {
                runner.analyzeEditedTranscript(record: record, transcript: editedTranscript,
                                               workspace: workspace, materials: materials)
            } else {
                runner.run(url: record.sourceURL, title: record.title,
                           meetingContext: record.meetingContext ?? "",
                           minutesTemplateID: record.minutesTemplateID ?? MinutesTemplate.general.id,
                           workspace: workspace,
                           tags: record.tags ?? [], materials: materials)
            }
        }
    }

    private func resume(_ job: PendingMeetingJob) {
        let source = URL(fileURLWithPath: job.sourcePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            PendingJobStore.clear(id: job.id)
            return
        }
        Task {
            let workspace = (try? MeetingWorkspaceStore.load())?
                .first { $0.id == job.workspaceID }
            var materials: [SupportingMaterial] = []
            for path in job.materialPaths {
                if let value = try? await Task.detached(operation: {
                    try MaterialExtractor.extract(from: URL(fileURLWithPath: path))
                }).value { materials.append(value) }
            }
            runner.run(url: source, title: job.title, meetingContext: job.meetingContext ?? "",
                       minutesTemplateID: job.minutesTemplateID ?? MinutesTemplate.general.id,
                       workspace: workspace, tags: job.tags, materials: materials)
        }
    }
}

// MARK: - Drop zone

private struct DropZone: View {
    @Binding var isTargeted: Bool
    let error: String?
    let recordingMonitor: SystemRecordingMonitor
    let onPick: (URL) -> Void

    @State private var rejection: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "wave.3.right.circle")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

            VStack(spacing: 6) {
                Text("把会议录像或录音拖到这里")
                    .font(.title3.weight(.medium))
                Text("支持 mov / mp4 / m4a / mp3 / wav —— 视频会自动提取音轨与屏幕画面")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button { openSystemScreenshot() } label: {
                    Label("使用系统截屏录制", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("使用系统截屏录制")
                Button("选择文件…") { pick() }
                    .accessibilityLabel("选择会议录像或录音文件")
            }
            .controlSize(.large)

            if let recording = recordingMonitor.detectedURL {
                Button {
                    if let url = recordingMonitor.consume() { accept(url) }
                } label: {
                    Label("导入刚录制的 \(recording.lastPathComponent)",
                          systemImage: "square.and.arrow.down")
                }
            } else if recordingMonitor.isWatching {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("等待系统录制完成，将自动发现保存到 \(recordingMonitor.folder.path) 的视频…")
                        .lineLimit(1)
                }.font(.caption).foregroundStyle(.secondary)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 40)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            Spacer()

            Text("音频与画面全程在本机处理；仅生成纪要这一步会调用模型。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(20)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in accept(url) }
            }
            return true
        }
        .alert("无法处理这个文件", isPresented: Binding(
            get: { rejection != nil }, set: { if !$0 { rejection = nil } }
        )) {
            Button("好") { rejection = nil }
        } message: {
            Text(rejection ?? "")
        }
    }

    /// Reject non-media up front — otherwise the failure surfaces minutes later
    /// as an opaque AVFoundation error.
    private func accept(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            rejection = "文件不存在或已被移动。"
            return
        }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard let type, type.conforms(to: .audiovisualContent) else {
            let name = url.lastPathComponent
            rejection = "「\(name)」不是音频或视频文件。\n"
                + "支持的格式：mov、mp4、m4a、mp3、wav 等。"
            return
        }
        onPick(url)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { accept(url) }
    }

    private func openSystemScreenshot() {
        recordingMonitor.begin()
        let workspace = NSWorkspace.shared
        let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.screenshot.launcher")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        if !workspace.open(url) {
            recordingMonitor.stop()
            rejection = "无法启动 macOS 系统截屏工具。也可以按 Shift–Command–5 打开。"
        }
    }
}

// MARK: - Analysis failed, transcript intact

/// Shown when the model call fails after transcription succeeded. The costly
/// work is already done, so the fix (key, provider, network) is a settings
/// change away and the retry is seconds rather than minutes.
private struct RetryPanel: View {
    let runner: PipelineRunner
    @Binding var showSettings: Bool
    @State private var exportedTranscript: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.orange)

            Text("生成纪要失败")
                .font(.title3.weight(.medium))

            if let error = runner.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
            }

            if let assets = runner.assets {
                Label("转录与画面已保留（\(assets.transcript.segments.count) 段语音"
                      + (assets.captures.isEmpty ? "" : "，\(assets.captures.count) 个画面")
                      + "），修好后可直接重试，无需重新转录",
                      systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 12) {
                Button("打开设置") { showSettings = true }
                Button("重试生成纪要") { runner.retryAnalysis() }
                    .keyboardShortcut(.defaultAction)
                Button("导出逐字稿") { exportTranscript() }
            }
            .controlSize(.large)

            if let exportedTranscript {
                Text("逐字稿已保存到 \(exportedTranscript)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    /// Escape hatch: keep the transcript even if the model never cooperates.
    private func exportTranscript() {
        guard let assets = runner.assets else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(assets.title) 逐字稿.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try assets.transcript.timecodedText.write(to: url, atomically: true, encoding: .utf8)
            exportedTranscript = url.lastPathComponent
        } catch {
            exportedTranscript = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Progress

private struct ProgressPanel: View {
    let runner: PipelineRunner

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 14) {
                Text(runner.stage.label)
                    .font(.title2.weight(.medium))

                if runner.progress > 0 {
                    ProgressView(value: runner.progress)
                        .frame(width: 320)
                } else {
                    ProgressView()
                        .frame(width: 320)
                }

                Text(runner.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            StageTrack(current: runner.stage)

            Button("取消", role: .cancel) { runner.cancel() }
                .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StageTrack: View {
    let current: PipelineRunner.Stage

    private let ordered: [PipelineRunner.Stage] = [
        .probing, .extractingAudio, .transcribing, .extractingFrames, .readingScreen, .analyzing,
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ordered, id: \.self) { stage in
                let index = ordered.firstIndex(of: stage) ?? 0
                let currentIndex = ordered.firstIndex(of: current) ?? -1
                HStack(spacing: 5) {
                    Circle()
                        .fill(index <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 7, height: 7)
                    Text(stage.label)
                        .font(.caption)
                        .foregroundStyle(index <= currentIndex ? .primary : .tertiary)
                }
            }
        }
    }
}

// MARK: - Result

private struct ResultView: View {
    let runner: PipelineRunner
    @Binding var savedPath: String?

    @State private var mode: Mode = .rendered
    @State private var savedURL: URL?
    @State private var saveError: String?
    @State private var showNaming = false
    @State private var showFeedback = false
    @State private var showEmail = false

    private enum Mode: String, CaseIterable {
        case rendered = "预览"
        case source = "源码"
    }

    /// Writing next to the source fails on read-only locations (disk images,
    /// some synced folders). Fall back to a save panel rather than doing
    /// nothing — a dead button gives the user no way forward.
    private func save() -> URL? {
        saveError = nil
        do {
            let url = try runner.saveOutputs()
            savedURL = url
            savedPath = url.deletingLastPathComponent().lastPathComponent
            return url
        } catch {
            guard let assets = runner.assets else {
                saveError = error.localizedDescription
                return nil
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(assets.title) 纪要.md"
            panel.message = "无法写入原文件所在目录，请另选位置"
            guard panel.runModal() == .OK, let picked = panel.url else { return nil }
            do {
                let url = try runner.saveOutputs(to: picked.deletingLastPathComponent())
                savedURL = url
                savedPath = url.deletingLastPathComponent().lastPathComponent
                return url
            } catch {
                saveError = "保存失败：\(error.localizedDescription)"
                return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .rendered:
                MarkdownView(markdown: runner.summary)
            case .source:
                ScrollView {
                    Text(runner.summary)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            }

            Divider()

            HStack(spacing: 12) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)

                if let assets = runner.assets {
                    Label("\(assets.transcript.segments.count) 段语音", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !assets.captures.isEmpty {
                        Label("\(assets.captures.count) 个画面", systemImage: "photo.on.rectangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if runner.structuredSummary != nil {
                        Label("结构化", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("已生成可供历史和跨会议分析使用的结构化 JSON")
                    } else if runner.usedSummaryFallback {
                        Label("格式回退", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("模型未返回合法 JSON，已保留其原始输出")
                    }
                    if !assets.tags.isEmpty {
                        Text(assets.tags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else if let historyWarning = runner.historyWarning {
                    Label(historyWarning, systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let savedPath {
                    Text("已保存到 \(savedPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                if let diarization = runner.assets?.diarization {
                    if !diarization.embeddings.isEmpty {
                        Button {
                            showNaming = true
                        } label: {
                            Label("登记/更新 \(diarization.speakerCount) 位说话人声纹", systemImage: "person.wave.2")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                        .help("试听并确认姓名；确认后才会加入声纹档案")
                    }

                    Button("重新分离") {
                        runner.rerunSpeakerSeparation()
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .help("按设置中的实际发言人数重新分离；复用转录缓存")
                }

                if runner.savedRecordID != nil {
                    Button("同步邮件") { showEmail = true }
                    Button("反馈") { showFeedback = true }
                        .help("评价纪要并提交待审核的术语候选")
                }

                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.summary, forType: .string)
                }

                Button("保存") {
                    if let url = save() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .keyboardShortcut("s")

                // Hands the file to whatever the user's default .md app is —
                // Typora, Obsidian, MacDown, VS Code…
                Button("用其他应用打开") {
                    if let url = savedURL ?? save() {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showNaming) {
            if let assets = runner.assets {
                SpeakerNamingView(assets: assets) { names in
                    showNaming = false
                    runner.applySpeakerNamesAndRegenerate(names)
                } onCancel: {
                    showNaming = false
                }
            }
        }
        .sheet(isPresented: $showFeedback) {
            if let id = runner.savedRecordID, let title = runner.assets?.title {
                MeetingFeedbackView(meetingID: id, title: title) { request in
                    runner.regenerate(withFeedback: request)
                }
            }
        }
        .sheet(isPresented: $showEmail) {
            if let id = runner.savedRecordID, let assets = runner.assets {
                MeetingEmailView(meetingID: id, title: assets.title,
                                 workspaceName: assets.workspace?.name,
                                 minutesTemplateID: assets.minutesTemplateID,
                                 workspaceEmailTemplateID: assets.workspace?.defaultEmailTemplateID,
                                 minutes: runner.summary)
            }
        }
    }
}
