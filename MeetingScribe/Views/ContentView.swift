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
                         onOpenLibrary: { showHistory = true },
                         onOpenSettings: { showSettings = true },
                         onPick: { pendingInput = $0 })
            case .done:
                ResultView(runner: runner, savedPath: $savedPath)
            case .reviewingIssues:
                IssuePreflightView(runner: runner)
            case .reviewingRequest:
                RequestPreviewView(runner: runner)
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
            if let draft = PendingIssueReviewStore.load() {
                restore(draft)
            } else if interruptedJob == nil {
                interruptedJob = PendingJobStore.load()
            }
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
                           meetingGroupID: record.meetingGroupID ?? record.id,
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
        let paths = job.sourcePaths ?? [job.sourcePath]
        let urls = paths.map(URL.init(fileURLWithPath:))
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
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
            do {
                switch try MeetingInput.classify(urls) {
                case .media(let source):
                    runner.run(url: source, meetingGroupID: job.meetingGroupID,
                               title: job.title, meetingContext: job.meetingContext ?? "",
                               minutesTemplateID: job.minutesTemplateID ?? MinutesTemplate.general.id,
                               recognitionScenario: job.recognitionScenario ?? .autoMultilingual,
                               workspace: workspace, customerName: job.customerName ?? "",
                               projectName: job.projectName ?? "", tags: job.tags, materials: materials)
                case .externalTranscript(let package):
                    runner.run(imported: package, title: job.title,
                               meetingGroupID: job.meetingGroupID,
                               meetingContext: job.meetingContext ?? "",
                               minutesTemplateID: job.minutesTemplateID ?? MinutesTemplate.general.id,
                               recognitionScenario: job.recognitionScenario ?? .autoMultilingual,
                               workspace: workspace, customerName: job.customerName ?? "",
                               projectName: job.projectName ?? "", tags: job.tags, materials: materials)
                }
            } catch {
                PendingJobStore.clear(id: job.id)
            }
        }
    }

    private func restore(_ draft: PendingIssueReviewDraft) {
        Task {
            var materials: [SupportingMaterial] = []
            for path in draft.materialPaths {
                if let value = try? await Task.detached(operation: {
                    try MaterialExtractor.extract(from: URL(fileURLWithPath: path))
                }).value { materials.append(value) }
            }
            runner.restoreIssueReview(draft, materials: materials)
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
    let onOpenLibrary: () -> Void
    let onOpenSettings: () -> Void
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

    private var pendingIssueCount: Int {
        ((try? ProjectLedgerStore.load())?.issueProposals ?? [])
            .filter { $0.resolution == .pending }.count
    }

    private var monthlyTokenUsage: Int {
        let calendar = Calendar.current
        return TokenUsageLedger.load().filter {
            calendar.isDate($0.startedAt, equalTo: Date(), toGranularity: .month)
        }.reduce(0) { $0 + $1.totalTokens }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isTargeted ? "松开即可导入" : "今天要处理什么会议？")
                        .font(.system(size: 26, weight: .bold))
                    Text("录制或导入会议，自动生成可追踪的项目纪要。")
                        .font(.callout).foregroundStyle(.secondary)
                }

                homeActions

                if recordingMonitor.isWatching {
                VStack(spacing: 8) {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("等待系统录制完成").font(.callout.weight(.medium))
                    }
                    Text("请在系统录屏工具中选择录制范围并确认麦克风；结束后将自动进入会议准备。")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("取消等待") { recordingMonitor.stop() }
                        Button("重新打开系统录屏") { openSystemScreenshot() }
                        Button("手动导入录屏") { pick() }
                    }.controlSize(.small)
                }
                } else if recordingMonitor.didTimeOut {
                VStack(spacing: 7) {
                    Text("暂未发现新的系统录屏").font(.callout.weight(.medium))
                    Text("录屏可能保存到了其他位置，可以手动选择文件或重新等待。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("重新等待") { openSystemScreenshot() }
                        Button("手动导入录屏") { pick() }
                    }.controlSize(.small)
                }
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
                    HStack {
                        Text("最近会议").font(.headline)
                        Spacer()
                        Button("查看全部", action: onOpenLibrary).buttonStyle(.link)
                    }
                    VStack(alignment: .leading, spacing: 0) {
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
                            .padding(.horizontal, 14).padding(.vertical, 11)
                        }.buttonStyle(.plain)
                        if record.id != recentMeetings.last?.id { Divider().padding(.leading, 14) }
                    }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)) }
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("需要关注").font(.headline)
                        if pendingIssueCount > 0 {
                            Button("\(pendingIssueCount) 个项目问题更新待确认", action: onOpenLibrary)
                                .buttonStyle(.link)
                        } else {
                            Label("没有需要确认的项目更新", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.callout).frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                    .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)) }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("本月模型用量").font(.headline); Spacer(); Button("明细", action: onOpenSettings).buttonStyle(.link) }
                        Text("\(monthlyTokenUsage.formatted()) Token")
                            .font(.title3.monospacedDigit().weight(.semibold))
                        Text("单次高消耗提醒：\(Settings.shared.tokenWarningThreshold.formatted()) Token")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                    .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)) }
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

            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            Color.accentColor.opacity(isTargeted ? 0.07 : 0)
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
        .onChange(of: recordingMonitor.detectedURL) { _, url in
            guard let url else { return }
            _ = recordingMonitor.consume()
            accept([url])
        }
        .alert("无法导入所选文件", isPresented: Binding(
            get: { rejection != nil }, set: { if !$0 { rejection = nil } }
        )) {
            Button("好") { rejection = nil }
        } message: {
            Text(rejection ?? "")
        }
    }

    private var homeActions: some View {
        HStack(spacing: 14) {
            Button { openSystemScreenshot() } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: "record.circle.fill").font(.title2)
                    Text("录制会议").font(.title3).fontWeight(.semibold)
                    Text("使用 macOS 系统录屏，完成后自动处理")
                        .font(.caption).foregroundStyle(.white.opacity(0.82))
                }
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                .padding(18)
            }.buttonStyle(HomePrimaryActionStyle())

            compactAction(title: "导入会议", subtitle: "音频、视频或 SRT",
                          icon: "square.and.arrow.down", action: pick)
            compactAction(title: "会议资料库", subtitle: "查找已有纪要",
                          icon: "books.vertical", action: onOpenLibrary)
        }
    }

    private func compactAction(title: String, subtitle: String, icon: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 155, alignment: .leading)
            .frame(minHeight: 92, alignment: .leading)
            .padding(18)
        }.buttonStyle(HomeSecondaryActionStyle())
    }

    private func accept(_ urls: [URL]) {
        do {
            let input = try MeetingInput.classify(urls)
            recordingMonitor.stop()
            onPick(input)
        }
        catch { rejection = error.localizedDescription }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent, .plainText,
                                     UTType(filenameExtension: "srt")!]
        panel.allowsMultipleSelection = true
        panel.message = "选择一个音频或视频；也可选择一份 SRT，并附带 TXT 和原始音频。TXT 不能单独导入。"
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

private struct HomePrimaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1),
                        in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: Color.accentColor.opacity(0.22), radius: 10, y: 5)
    }
}

private struct HomeSecondaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.secondary.opacity(configuration.isPressed ? 0.13 : 0.07),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2)) }
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

                if runner.stage.hasMeasurableProgress
                    && (runner.stage != .transcribing || runner.progress > 0) {
                    ProgressView(value: runner.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 320)
                    Text("\(Int((runner.progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 320)
                }

                Text(runner.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let estimate = runner.estimatedRemainingText {
                    Text(estimate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if runner.stage != .reviewingRequest {
                    Text("完成 2 次处理后，将根据本机历史显示剩余时间")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            StageTrack(current: runner.stage)

            Button("取消", role: .cancel) { runner.cancel() }
                .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension PipelineRunner.Stage {
    var hasMeasurableProgress: Bool {
        switch self {
        case .extractingAudio, .transcribing, .separatingSpeakers,
             .extractingFrames, .readingScreen:
            return true
        default:
            return false
        }
    }
}

private struct RequestPreviewView: View {
    let runner: PipelineRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("提交给大模型前预览").font(.title2.weight(.semibold))
                Text("以下是即将提交的实际文本；确认前不会调用大模型。")
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: .constant(runner.requestPreview))
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)) }
            HStack {
                Button("取消本次处理", role: .cancel) { runner.cancel() }
                Button("复制完整请求") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.requestPreview, forType: .string)
                }
                Spacer()
                Button("确认并生成纪要") { runner.confirmRequestPreview() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
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
