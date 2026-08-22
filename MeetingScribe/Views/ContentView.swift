import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var runner = PipelineRunner()
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var historySelection: UUID?
    @State private var recentMeetings: [MeetingRecord] = []
    @State private var isTargeted = false
    @State private var savedPath: String?
    @State private var pendingInput: MeetingInput?
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
                         recentMeetings: recentMeetings,
                         onOpenMeeting: { id in
                             historySelection = id
                             showHistory = true
                         },
                         onPick: { pendingInput = $0 })
            case .done:
                ResultView(runner: runner, savedPath: $savedPath)
            default:
                ProgressPanel(runner: runner)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .toolbar {
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
        .sheet(isPresented: $showHistory, onDismiss: {
            historySelection = nil
            loadRecentMeetings()
        }) {
            MeetingHistoryView(initialSelection: historySelection, onReprocess: { record in
                showHistory = false
                reprocess(record)
            }, onAnalyzeTranscript: { record, transcript in
                showHistory = false
                reprocess(record, editedTranscript: transcript)
            })
        }
        .sheet(isPresented: Binding(
            get: { pendingInput != nil },
            set: { if !$0 { pendingInput = nil } }
        )) {
            if let input = pendingInput {
                MeetingPreparationView(input: input) { title, scenario, workspace, context, templateID, customerName, projectName, tags, materials in
                    pendingInput = nil
                    switch input {
                    case .media(let url):
                        runner.run(url: url, title: title, meetingContext: context,
                                   minutesTemplateID: templateID,
                                   recognitionScenario: scenario,
                                   workspace: workspace, customerName: customerName,
                                   projectName: projectName, tags: tags, materials: materials)
                    case .externalTranscript(let package):
                        runner.run(imported: package, title: title, meetingContext: context,
                                   minutesTemplateID: templateID,
                                   recognitionScenario: scenario,
                                   workspace: workspace, customerName: customerName,
                                   projectName: projectName, tags: tags, materials: materials)
                    }
                } onCancel: {
                    pendingInput = nil
                }
            }
        }
        .onAppear {
            loadRecentMeetings()
            if interruptedJob == nil { interruptedJob = PendingJobStore.load() }
            Task { await AutomaticBackupManager.runIfNeeded() }
        }
        .onChange(of: runner.stage) { _, stage in
            if stage == .done { Task { await AutomaticBackupManager.runIfNeeded() } }
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

    private func loadRecentMeetings() {
        recentMeetings = Array(((try? MeetingHistoryStore.loadAll()) ?? [])
            .filter { $0.isArchived != true }
            .prefix(3))
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
            } else if record.sourceKind == MeetingAssets.SourceKind.importedTranscript.rawValue {
                runner.analyzeEditedTranscript(record: record, transcript: record.transcript,
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
                       recognitionScenario: job.recognitionScenario ?? .autoMultilingual,
                       workspace: workspace, customerName: job.customerName ?? "",
                       projectName: job.projectName ?? "", tags: job.tags, materials: materials)
        }
    }
}

// MARK: - Drop zone

private struct DropZone: View {
    @Binding var isTargeted: Bool
    let error: String?
    let recentMeetings: [MeetingRecord]
    let onOpenMeeting: (UUID) -> Void
    let onPick: (MeetingInput) -> Void

    @State private var rejection: String?

    private var modelReadiness: (String, Bool) {
        let settings = Settings.shared
        switch settings.backend {
        case .codexCLI:
            return ToolLocator.path(for: .codex) == nil
                ? ("Codex CLI 未安装", false) : ("Codex CLI 已就绪", true)
        case .claudeCLI:
            return ToolLocator.path(for: .claude) == nil
                ? ("Claude Code 未安装", false) : ("Claude Code 已就绪", true)
        case .openAICompatible:
            let ready = !settings.providerModel.isEmpty
                && (!settings.provider.requiresKey || settings.providerKeyExists)
            return ready ? ("\(settings.provider.name) 已就绪", true)
                : ("请完成 \(settings.provider.name) 配置", false)
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "wave.3.right.circle")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

            VStack(spacing: 6) {
                Text(isTargeted ? "松开即可导入" : "开始一次会议")
                    .font(.title2.weight(.semibold))
                Text("拖入录音、录像，或妙记导出的逐字稿")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button { pick() } label: {
                Label("导入会议", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 40)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            if !recentMeetings.isEmpty {
                Divider().frame(maxWidth: 500)
                VStack(alignment: .leading, spacing: 7) {
                    Text("最近会议").font(.headline)
                    ForEach(recentMeetings) { record in
                        Button { onOpenMeeting(record.id) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "doc.text").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.title).lineLimit(1)
                                    Text(record.createdAt.formatted(date: .abbreviated,
                                                                   time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if record.openActionCount > 0 {
                                    Text("\(record.openActionCount) 项待办")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3)
                        }.buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 500, alignment: .leading)
            }

            HStack(spacing: 6) {
                Circle().fill(modelReadiness.1 ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(modelReadiness.0)
            }
            .font(.caption).foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: 560, maxHeight: .infinity)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3))
                }
                .padding(.vertical, 18)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard !providers.isEmpty else { return false }
            let group = DispatchGroup()
            let lock = NSLock()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { accept(urls) }
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

    private func accept(_ urls: [URL]) {
        do { onPick(try MeetingInput.classify(urls)) }
        catch { rejection = error.localizedDescription }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent, .plainText,
                                     UTType(filenameExtension: "srt")!]
        panel.allowsMultipleSelection = true
        panel.message = "可选择单个录音/录像，或同时选择妙记 SRT、TXT 和原始音频"
        if panel.runModal() == .OK { accept(panel.urls) }
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
    @State private var showRecognitionLearning = false
    @State private var showSpeakerRetry = false

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
                if let stats = runner.assets?.adaptiveScreenReviewStats {
                    Label(stats.summary, systemImage: "viewfinder")
                        .font(.caption)
                        .foregroundStyle(stats.citedScreenEvidence > 0 ? Color.green : Color.secondary)
                        .help("逐字稿驱动的补充画面分析链路统计")
                }
                if runner.usedSummaryFallback {
                    Label("纪要格式不完整，已保留模型原文", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
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

                if runner.savedRecordID != nil {
                    Button("生成邮件") { showEmail = true }
                }

                Button("纠正并学习") { showRecognitionLearning = true }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.summary, forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }

                Button {
                    if let url = save() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .keyboardShortcut("s")

                Menu("更多", systemImage: "ellipsis.circle") {
                    Button(mode == .rendered ? "查看 Markdown 源码" : "返回纪要预览") {
                        mode = mode == .rendered ? .source : .rendered
                    }
                    if let diarization = runner.assets?.diarization {
                        Divider()
                        if !diarization.embeddings.isEmpty {
                            Button("登记或更新说话人声纹…") { showNaming = true }
                        }
                        Button("重新分离说话人…") { showSpeakerRetry = true }
                    }
                    if runner.savedRecordID != nil {
                        Divider()
                        Button("反馈并改进纪要…") { showFeedback = true }
                    }
                    Divider()
                    Button("用默认 Markdown 应用打开") {
                        do {
                            try MinutesDocumentOpener.open(
                                markdown: runner.summary,
                                title: runner.assets?.title ?? "会议纪要")
                        } catch {
                            saveError = "打开纪要失败：\(error.localizedDescription)"
                        }
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
        .sheet(isPresented: $showSpeakerRetry) {
            SpeakerRetryView(detectedCount: runner.assets?.diarization?.speakerCount ?? 0) { count in
                showSpeakerRetry = false
                runner.rerunSpeakerSeparation(speakerCount: count)
            } onCancel: {
                showSpeakerRetry = false
            }
        }
        .sheet(isPresented: $showFeedback) {
            if let id = runner.savedRecordID, let title = runner.assets?.title {
                MeetingFeedbackView(meetingID: id, title: title) { request in
                    runner.regenerate(withFeedback: request)
                }
            }
        }
        .sheet(isPresented: $showRecognitionLearning) {
            if let assets = runner.assets {
                RecognitionLearningView(
                    workspaceID: assets.workspace?.id,
                    sourceTitle: assets.title,
                    uncertainties: runner.structuredSummary?.uncertainties ?? []) {
                        runner.applyRecognitionMemoryAndRegenerate()
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

private struct SpeakerRetryView: View {
    let detectedCount: Int
    let onRun: (Int) -> Void
    let onCancel: () -> Void
    @State private var count = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重新分离说话人").font(.title3.weight(.medium))
            Text("通常保持自动判断即可。如果当前结果人数明显不对，可以指定这段录音中真正开口的人数。")
                .font(.callout).foregroundStyle(.secondary)
            Picker("实际发言人数", selection: $count) {
                Text("自动判断").tag(0)
                ForEach(2...30, id: \.self) { Text("\($0) 人").tag($0) }
            }
            if detectedCount > 0 {
                Text("当前识别结果：\(detectedCount) 人")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("重新分离") { onRun(count) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}
