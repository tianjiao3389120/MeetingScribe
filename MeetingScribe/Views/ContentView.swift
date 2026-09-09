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
                         recentMeetings: recentMeetings,
                         onOpenMeeting: { id in
                             historySelection = id
                             showHistory = true
                         },
                         onPick: { pendingInput = $0 })
            case .done:
                ResultView(runner: runner, savedPath: $savedPath)
            case .reviewingIssues:
                IssuePreflightView(runner: runner)
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
            let workspace = MeetingWorkspaceStore.resolve(
                id: record.workspaceID, customerName: record.customerName,
                projectName: record.projectName)
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
                runner.run(url: record.sourceURL, recordedAt: record.createdAt,
                           title: record.title,
                           meetingContext: record.meetingContext ?? "",
                           minutesTemplateID: record.minutesTemplateID ?? MinutesTemplate.general.id,
                           workspace: workspace,
                           speakerNames: record.speakerNames,
                           speakerRoles: record.speakerRoles ?? [:],
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
    let recordingMonitor: SystemRecordingMonitor
    let recentMeetings: [MeetingRecord]
    let onOpenMeeting: (UUID) -> Void
    let onPick: (MeetingInput) -> Void

    @State private var rejection: String?

    private struct ReadinessItem: Identifiable {
        let id: String
        let text: String
        let ready: Bool
    }

    private var runtimeReadiness: [ReadinessItem] {
        let settings = Settings.shared
        let transcriptionReady = ToolLocator.path(for: .whisper) != nil
            && ToolLocator.modelPath() != nil
            && ToolLocator.vadModelPath() != nil
        let speakerReady = Diarizer.readiness().isReady
        let model: ReadinessItem
        switch settings.backend {
        case .codexCLI:
            model = ToolLocator.path(for: .codex) == nil
                ? ReadinessItem(id: "model", text: "纪要引擎 · Codex CLI 未安装", ready: false)
                : ReadinessItem(id: "model", text: "纪要引擎 · Codex CLI", ready: true)
        case .claudeCLI:
            model = ToolLocator.path(for: .claude) == nil
                ? ReadinessItem(id: "model", text: "纪要引擎 · Claude Code 未安装", ready: false)
                : ReadinessItem(id: "model", text: "纪要引擎 · Claude Code", ready: true)
        case .openAICompatible:
            let ready = !settings.providerModel.isEmpty
                && (!settings.provider.requiresKey || settings.providerKeyExists)
            model = ready
                ? ReadinessItem(id: "model", text: "纪要引擎 · \(settings.provider.name)", ready: true)
                : ReadinessItem(id: "model", text: "纪要引擎 · 请配置 \(settings.provider.name)", ready: false)
        }
        return [
            ReadinessItem(id: "transcription", text: transcriptionReady ? "转录引擎 · Whisper" : "转录引擎 · 未就绪", ready: transcriptionReady),
            ReadinessItem(id: "speakers", text: speakerReady ? "声纹引擎 · 已就绪" : "声纹引擎 · 未安装", ready: speakerReady),
            model,
        ]
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

            HStack(spacing: 10) {
                Button { pick() } label: {
                    Label("导入会议", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                Button { openSystemScreenshot() } label: {
                    Label("录制会议", systemImage: "record.circle")
                }
            }
            .controlSize(.large)

            if let recording = recordingMonitor.detectedURL {
                Button {
                    if let url = recordingMonitor.consume() { accept([url]) }
                } label: {
                    Label("导入刚录制的 \(recording.lastPathComponent)",
                          systemImage: "square.and.arrow.down")
                }
            } else if recordingMonitor.isWatching {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("等待系统录制完成…").lineLimit(1)
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

            HStack(spacing: 14) {
                ForEach(runtimeReadiness) { item in
                    HStack(spacing: 5) {
                        Circle().fill(item.ready ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(item.text)
                    }
                }
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

// MARK: - Issue preflight

private struct IssuePreflightView: View {
    struct Draft: Identifiable {
        let id = UUID()
        var issue: StructuredMinutes.Issue
        var excluded = false
    }

    let runner: PipelineRunner
    @State private var drafts: [Draft]
    private let historicalIssues: [ProjectIssue]

    init(runner: PipelineRunner) {
        self.runner = runner
        _drafts = State(initialValue: (runner.structuredSummary?.issues ?? []).map { Draft(issue: $0) })
        if let workspaceID = runner.assets?.workspace?.id {
            historicalIssues = (try? ProjectLedgerStore.load().issues(for: workspaceID)) ?? []
        } else {
            historicalIssues = []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("生成最终纪要前确认问题").font(.title2.weight(.semibold))
                Text("问题结构确认后才会保存纪要和建立问题关联。可以改名、排除、合并或直接关联历史问题。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(runner.issueReviewReasons, id: \.self) {
                    Label($0, systemImage: "exclamationmark.bubble")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Toggle("保留为问题", isOn: Binding(
                                    get: { !draft.excluded },
                                    set: { draft.excluded = !$0 }))
                                Spacer()
                                Menu("合并到…") {
                                    ForEach(drafts.filter { $0.id != draft.id && !$0.excluded }) { target in
                                        Button(target.issue.title) { merge(draft.id, into: target.id) }
                                    }
                                }.disabled(draft.excluded || drafts.filter { $0.id != draft.id && !$0.excluded }.isEmpty)
                                Button("拆分副本") { split(draft.id) }.disabled(draft.excluded)
                                Button("排除") { draft.excluded = true }.disabled(draft.excluded)
                            }
                            TextField("问题标题", text: $draft.issue.title)
                                .textFieldStyle(.roundedBorder).disabled(draft.excluded)
                            if !draft.issue.progress.isEmpty {
                                Text("本次进展：\(draft.issue.progress)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            if !historicalIssues.isEmpty && !draft.excluded {
                                Picker("历史关联", selection: $draft.issue.trackingID) {
                                    Text("作为新问题").tag(Optional<String>.none)
                                    ForEach(historicalIssues) { issue in
                                        Text(issue.title).tag(Optional(issue.id))
                                    }
                                }.controlSize(.small)
                                if let selectedID = draft.issue.trackingID,
                                   let selected = historicalIssues.first(where: { $0.id == selectedID }) {
                                    ProjectIssueHistorySummaryView(issue: selected)
                                }
                            }
                        }
                        .padding(12)
                        .opacity(draft.excluded ? 0.55 : 1)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
                    }
                }.padding(20)
            }
            Divider()
            HStack {
                Text("保留 \(drafts.filter { !$0.excluded }.count) 个问题")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("确认并生成最终纪要") {
                    runner.finalizeIssueReview(drafts.filter { !$0.excluded }.map(\.issue))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }.padding(16)
        }
    }

    private func merge(_ sourceID: UUID, into targetID: UUID) {
        guard let source = drafts.firstIndex(where: { $0.id == sourceID }),
              let target = drafts.firstIndex(where: { $0.id == targetID }) else { return }
        drafts[target].issue = IssuePreflight.merge(drafts[source].issue, into: drafts[target].issue)
        drafts[source].excluded = true
    }

    private func split(_ sourceID: UUID) {
        guard let source = drafts.firstIndex(where: { $0.id == sourceID }) else { return }
        var issue = drafts[source].issue
        issue.trackingID = nil
        issue.title += "（拆分）"
        drafts.insert(Draft(issue: issue), at: source + 1)
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
                        .progressViewStyle(.linear)
                        .frame(width: 320)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 320)
                }

                Text(runner.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            StageTrack(current: runner.stage)

            if Settings.shared.pipelineDebugEnabled {
                PipelineDebugPanel(session: runner.debugSession)
                    .frame(maxWidth: 620, maxHeight: 190)
            }

            Button("取消", role: .cancel) { runner.cancel() }
                .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PipelineDebugPanel: View {
    let session: PipelineDebugSession

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("流水线调试", systemImage: "ladybug")
                    .font(.headline)
                Spacer()
                if session.isPaused {
                    Text("等待确认")
                        .foregroundStyle(.orange)
                    Button("确认继续") { session.resume() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let logURL = session.logURL {
                Text("完整日志：\(logURL.path)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let node = session.pausedNode, let phase = session.pausedPhase {
                Text("已暂停：\(node) · \(phase.rawValue)。请检查下方输入/输出后确认继续。")
                    .font(.caption).foregroundStyle(.orange)
                if let command = session.continueCommand {
                    Text("终端确认：\(command)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(session.events) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.node) · \(event.phase.rawValue)")
                                .font(.caption.weight(.semibold))
                            Text(String(event.payload.prefix(600))
                                 + (event.payload.count > 600 ? "\n…完整内容请查看日志" : ""))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let image = event.image {
                                Image(decorative: image, scale: 1, orientation: .up)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        .padding(6)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.45)))
    }
}

private struct StageTrack: View {
    let current: PipelineRunner.Stage

    private let ordered: [PipelineRunner.Stage] = [
        .probing, .extractingAudio, .transcribing, .separatingSpeakers,
        .extractingFrames, .readingScreen, .analyzing,
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
    @State private var showMinutesVersions = false
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
                    Button("会议纪要") { showMinutesVersions = true }
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
                    if runner.assets?.diarization != nil {
                        Divider()
                        Button("确认说话人姓名与角色…") { showNaming = true }
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
                SpeakerNamingView(assets: assets) { names, roles in
                    showNaming = false
                    runner.applySpeakerNamesAndRegenerate(names, roles: roles)
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
        .sheet(isPresented: $showMinutesVersions) {
            if let id = runner.savedRecordID, let assets = runner.assets {
                MeetingMinutesVersionView(meetingID: id, title: assets.title,
                                 minutes: runner.structuredSummary.map(CustomerMinutesRenderer.markdown(from:))
                                     ?? runner.summary)
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
