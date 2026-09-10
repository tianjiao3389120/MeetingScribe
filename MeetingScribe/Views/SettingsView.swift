import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var modelStatus = ModelStatus.check()
    @State private var download: ModelDownloader?
    @State private var modelPackageMessage: String?
    @State private var showsGenerationEngine = false
    @State private var showsLocalRecognition = false
    @State private var showsTranscriptionEngine = false
    @State private var showsSpeakerEngine = false
    @State private var showsVisualEngine = false
    @State private var showsOfflineMigration = false
    @State private var cacheSummary = SettingsView.describeCache()
    @State private var showVoiceProfiles = false
    @State private var showRecognitionMemory = false
    @State private var recognitionMemoryCount = RecognitionMemoryStore.load().count
    @State private var voiceProfileCount = VoiceProfileStore.load().count
    @State private var showStorageManagement = false
    @State private var showRuntimeDiagnostics = false
    @State private var showTokenUsage = false
    @State private var glossaryCandidates = FeedbackStore.loadCandidates()
    @State private var glossaryCandidateError: String?

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
                Section("AI 引擎") {
                    DisclosureGroup(isExpanded: $showsGenerationEngine) {
                        generationEngineSettings.padding(.top, 8)
                    } label: {
                        enginePrimaryLabel("纪要生成", icon: "text.badge.star",
                                           subtitle: "在线或本机 CLI 大模型")
                    }
                    DisclosureGroup(isExpanded: $showsLocalRecognition) {
                        VStack(alignment: .leading, spacing: 12) {
                            transcriptionEngineSettings
                            Divider()
                            speakerEngineSettings
                            Divider()
                            visualEngineSettings
                        }.padding(.top, 8).padding(.leading, 18)
                    } label: {
                        enginePrimaryLabel("本地识别", icon: "cpu",
                                           subtitle: "转录、说话人与画面")
                    }
                    DisclosureGroup(isExpanded: $showsOfflineMigration) {
                        offlineMigrationSettings.padding(.top, 8)
                    } label: {
                        enginePrimaryLabel("离线迁移", icon: "shippingbox",
                                           subtitle: "导入或导出本地引擎")
                    }
                }

                Section("会议纪要指令") {
                    TextEditor(text: $settings.minutesInstructions)
                        .frame(height: 85).font(.callout)
                    HStack {
                        Text("追加到内置的结构化纪要提示词；JSON 格式和事实校验规则由应用固定维护。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") {
                            settings.minutesInstructions = Settings.defaultMinutesInstructions
                        }.buttonStyle(.link)
                    }
                }

                Section("识别学习") {
                    LabeledContent("已学习") {
                        HStack(spacing: 10) {
                            Text("\(recognitionMemoryCount) 条").foregroundStyle(.secondary)
                            Button("管理…") { showRecognitionMemory = true }
                        }
                    }
                    Text("在会议结果中纠正术语或登记姓名后，后续会议会自动使用；项目词不会影响其他会议。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !glossaryCandidates.isEmpty {
                        DisclosureGroup("待审核术语（\(glossaryCandidates.count)）") {
                            ForEach(glossaryCandidates) { candidate in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.term)
                                        Text("来自：\(candidate.sourceTitle)")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("加入") { accept(candidate) }
                                        .disabled(!canAccept(candidate))
                                    Button(role: .destructive) { discard(candidate) } label: {
                                        Image(systemName: "xmark")
                                    }.buttonStyle(.borderless)
                                }
                            }
                        }
                        if let glossaryCandidateError {
                            Text(glossaryCandidateError).font(.caption).foregroundStyle(.red)
                        }
                    }
                    DisclosureGroup("兼容旧版手工词表") {
                        TextEditor(text: $settings.glossary)
                            .frame(height: 80).font(.system(.caption, design: .monospaced))
                        Text("旧词表仍参与识别；新内容建议通过“纠正并学习”录入。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section("存储") {
                    LabeledContent("处理缓存") { Text(cacheSummary).foregroundStyle(.secondary) }
                    Button("管理存储…") { showStorageManagement = true }
                }

                Section("Token 用量") {
                    let usage = TokenUsageLedger.load()
                    LabeledContent("应用总计",
                                   value: usage.reduce(0) { $0 + $1.totalTokens }.formatted())
                    Stepper(value: $settings.tokenWarningThreshold,
                            in: 2_000...100_000, step: 2_000) {
                        LabeledContent("高消耗提醒阈值",
                                       value: "\(settings.tokenWarningThreshold.formatted()) Token")
                    }
                    Button("查看模型明细…") { showTokenUsage = true }
                    Text("所有模型功能统一记账；API 优先采用服务商实耗，CLI 或缺少 usage 的接口使用估算。达到阈值的会议任务会在开始前再次确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("高级诊断") {
                    DisclosureGroup("展开诊断选项") {
                        Button("运行环境诊断…", systemImage: "stethoscope") {
                            showRuntimeDiagnostics = true
                        }
                        Text("检查本地转录引擎、模型和大模型配置，不会调用接口。")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("保留临时音轨", isOn: $settings.keepIntermediates)
                        Toggle("生成最终纪要前始终确认问题", isOn: $settings.alwaysReviewIssues)
                            .help("关闭时仅在检测到问题可能重复、从属或边界不清时暂停确认")
                        Text("仅用于排查转录问题，会持续占用临时目录空间；正常使用建议关闭。")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle("启用隐藏的数据流调试日志", isOn: $settings.pipelineDebugEnabled)
                        Toggle("每个节点运行中暂停确认",
                               isOn: $settings.pipelineDebugPauseAtNodeStart)
                            .disabled(!settings.pipelineDebugEnabled)
                        Text("调试信息和中间产物只写入 ~/Library/Application Support/MeetingScribe/Debug，界面不展示大段内容。终端查看：tail -f \"$HOME/Library/Application Support/MeetingScribe/Debug/latest.log\"")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
        .sheet(isPresented: $showRecognitionMemory, onDismiss: {
            recognitionMemoryCount = RecognitionMemoryStore.load().count
        }) { RecognitionMemoryManagementView() }
        .sheet(isPresented: $showStorageManagement, onDismiss: {
            cacheSummary = Self.describeCache()
        }) { StorageManagementView() }
        .sheet(isPresented: $showRuntimeDiagnostics) { RuntimeDiagnosticsView() }
        .sheet(isPresented: $showTokenUsage) { TokenUsageOverviewView() }
    }

    private func enginePrimaryLabel(_ title: String, icon: String,
                                    subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }

    private func engineSecondaryLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var generationEngineSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("运行方式", selection: $settings.backend) {
                Text(BackendKind.codexCLI.displayName).tag(BackendKind.codexCLI)
                Text(BackendKind.claudeCLI.displayName).tag(BackendKind.claudeCLI)
                Text(BackendKind.openAICompatible.displayName).tag(BackendKind.openAICompatible)
            }
            Text(settings.backend.explanation).font(.caption).foregroundStyle(.secondary)
            if settings.backend == .codexCLI {
                ToolRow(tool: .codex)
                Text("本机运行客户端，模型服务仍在云端；请先运行 codex login。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if settings.backend == .claudeCLI {
                ToolRow(tool: .claude)
                Text("本机运行客户端，模型服务仍在云端；请先完成 Claude Code 登录。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProviderSection(settings: $settings)
            }
        }
    }

    @ViewBuilder
    private var transcriptionEngineSettings: some View {
        DisclosureGroup(isExpanded: $showsTranscriptionEngine) {
            VStack(alignment: .leading, spacing: 10) {
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
                            VStack(alignment: .trailing, spacing: 4) {
                                Button(download?.detail.contains("失败") == true
                                       ? "继续下载" : "下载（约 1.5GB）") {
                                    let downloader = download ?? ModelDownloader()
                                    download = downloader
                                    Task {
                                        await downloader.run()
                                        modelStatus = ModelStatus.check()
                                    }
                                }
                                if let detail = download?.detail, !detail.isEmpty {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: 260, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
                Text("Whisper 与 VAD 均在本机运行；在线下载中断后可继续。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 6)
        } label: {
            engineSecondaryLabel("语音转录", icon: "waveform")
        }
    }

    @ViewBuilder
    private var speakerEngineSettings: some View {
        DisclosureGroup(isExpanded: $showsSpeakerEngine) {
            VStack(alignment: .leading, spacing: 10) {
                SpeakerSection().id(Diarizer.modelsPresent)
                LabeledContent("已登记声纹") {
                    HStack(spacing: 10) {
                        Text("\(voiceProfileCount) 人").font(.caption).foregroundStyle(.secondary)
                        Button("管理…") { showVoiceProfiles = true }
                    }
                }
                Text("声纹档案属于用户数据，不包含在离线引擎包中。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 6)
        } label: {
            engineSecondaryLabel("说话人分离", icon: "person.2.wave.2")
        }
    }

    @ViewBuilder
    private var visualEngineSettings: some View {
        DisclosureGroup(isExpanded: $showsVisualEngine) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("处理方式") {
                    Label("系统内置", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Picker("采样密度", selection: $settings.frameDensity) {
                    ForEach(FrameDensity.allCases) { Text($0.displayName).tag($0) }
                }
                Text("抽帧、去重和 macOS Vision OCR 均在本机完成，无需下载额外视觉模型；支持视觉的纪要模型可进一步理解筛选后的原图。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 6)
        } label: {
            engineSecondaryLabel("画面分析", icon: "viewfinder")
        }
    }

    @ViewBuilder
    private var offlineMigrationSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("语音识别模型") { engineStatus(modelStatus == .ready) }
            LabeledContent("说话人分离模型") { engineStatus(Diarizer.modelsPresent) }
            LabeledContent("画面分析") { Label("macOS 内置，无需迁移", systemImage: "apple.logo") }
            VStack(alignment: .leading, spacing: 4) {
                Text(Diarizer.modelsPresent
                     ? "本次导出包含：Whisper、VAD、说话人分段、声纹模型"
                     : "本次导出包含：Whisper、VAD")
                Text(Diarizer.modelsPresent
                     ? "不包含：CLI、Python 环境、API Key、用户声纹档案"
                     : "未包含：说话人分离模型（尚未安装）")
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("导入离线引擎包…") { importRecognitionModels() }
                Button("导出离线引擎包…") { exportRecognitionModels() }
                    .disabled(modelStatus != .ready)
            }
            if let modelPackageMessage {
                Text(modelPackageMessage).font(.caption)
                    .foregroundStyle(modelPackageMessage.contains("失败")
                                     ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func exportRecognitionModels() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MeetingScribe离线引擎包.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelPackageMessage = "正在校验并生成离线引擎包…"
        Task {
            do {
                try await Task.detached { try RecognitionModelPackage.export(to: url) }.value
                modelPackageMessage = Diarizer.modelsPresent
                    ? "离线引擎包已导出，包含识别与说话人模型。"
                    : "离线引擎包已导出，当前未安装说话人模型。"
            } catch { modelPackageMessage = "导出失败：\(error.localizedDescription)" }
        }
    }

    @ViewBuilder
    private func engineStatus(_ ready: Bool) -> some View {
        Label(ready ? "已就绪" : "未安装",
              systemImage: ready ? "checkmark.circle.fill" : "minus.circle")
            .foregroundStyle(ready ? Color.green : Color.secondary)
    }

    private func importRecognitionModels() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelPackageMessage = "正在校验并导入模型…"
        Task {
            do {
                try await Task.detached { try RecognitionModelPackage.importPackage(from: url) }.value
                modelStatus = ModelStatus.check()
                modelPackageMessage = Diarizer.modelsPresent
                    ? "识别与说话人模型已导入；请检查运行环境。"
                    : "识别模型已导入；该包不包含说话人模型。"
            } catch { modelPackageMessage = "导入失败：\(error.localizedDescription)" }
        }
    }

    private func canAccept(_ candidate: GlossaryCandidate) -> Bool {
        !candidate.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func accept(_ candidate: GlossaryCandidate) {
        do {
            try RecognitionMemoryStore.upsert(RecognitionMemoryEntry(
                canonical: candidate.term, sourceTitle: candidate.sourceTitle))
            recognitionMemoryCount = RecognitionMemoryStore.load().count
            discard(candidate)
        } catch { glossaryCandidateError = error.localizedDescription }
    }

    private func discard(_ candidate: GlossaryCandidate) {
        do {
            try FeedbackStore.removeCandidate(id: candidate.id)
            glossaryCandidates.removeAll { $0.id == candidate.id }
            glossaryCandidateError = nil
        } catch { glossaryCandidateError = error.localizedDescription }
    }
}

private struct TokenUsageOverviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [TokenUsageEntry] = []
    @State private var recordsByID: [UUID: MeetingRecord] = [:]

    private var input: Int { rows.reduce(0) { $0 + $1.inputTokens } }
    private var output: Int { rows.reduce(0) { $0 + $1.outputTokens } }
    private var total: Int { input + output }
    private var calls: Int { rows.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Token 用量统计").font(.title3.weight(.semibold))
                    Text("每次模型调用均记录，可按客户 / 项目 / 纪要 / 功能核对")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()

            if rows.isEmpty {
                ContentUnavailableView("暂无用量记录", systemImage: "chart.bar",
                                       description: Text("生成或重新生成一场会议后会开始统计。"))
            } else {
                HStack(spacing: 28) {
                    metric("总 Token", total)
                    metric("输入", input)
                    metric("输出", output)
                    metric("调用次数", calls)
                }
                .frame(maxWidth: .infinity).padding(18)
                Divider()
                Table(rows) {
                    TableColumn("时间") { Text($0.startedAt.formatted(date: .numeric, time: .shortened)) }
                        .width(min: 120, ideal: 135)
                    TableColumn("客户") { Text(customer(for: $0)) }.width(80)
                    TableColumn("项目") { Text(project(for: $0)) }.width(90)
                    TableColumn("纪要 / 对象") { Text(label($0.meetingTitle, fallback: "未关联")) }
                        .width(min: 120, ideal: 170)
                    TableColumn("功能") { Text($0.feature) }.width(110)
                    TableColumn("模型") { Text($0.model) }.width(105)
                    TableColumn("输入") { Text($0.inputTokens.formatted()) }.width(65)
                    TableColumn("输出") { Text($0.outputTokens.formatted()) }.width(65)
                    TableColumn("总计") {
                        Text($0.totalTokens.formatted()).fontWeight(.medium)
                    }.width(70)
                    TableColumn("口径 / 结果") {
                        Text("\($0.isEstimated ? "估算" : "实耗") · \(status($0.status))")
                    }.width(85)
                }
            }
        }
        .frame(width: 1180, height: 540)
        .onAppear {
            rows = TokenUsageLedger.load().sorted { $0.startedAt > $1.startedAt }
            let records = (try? MeetingHistoryStore.loadAll()) ?? []
            var index: [UUID: MeetingRecord] = [:]
            for record in records {
                index[record.id] = record
                index[record.meetingGroupID ?? record.id] = record
            }
            recordsByID = index
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title3.monospacedDigit().weight(.semibold))
        }
    }

    private func status(_ status: TokenUsageEntry.Status) -> String {
        switch status { case .succeeded: "成功"; case .failed: "失败"; case .cancelled: "取消" }
    }

    private func label(_ value: String?, fallback: String) -> String {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func customer(for entry: TokenUsageEntry) -> String {
        label(entry.customer ?? entry.meetingID.flatMap { recordsByID[$0]?.customerName },
              fallback: "未知")
    }

    private func project(for entry: TokenUsageEntry) -> String {
        label(entry.project ?? entry.meetingID.flatMap { recordsByID[$0]?.projectName },
              fallback: "未分类")
    }
}

/// Install, enable and tune speaker separation.
private struct SpeakerSection: View {
    @State private var readiness = Diarizer.readiness()
    @State private var installing = false
    @State private var installDetail = ""
    @State private var installError: String?

    var body: some View {
        Text("处理会议时会自动区分实际发言人，让纪要保留「谁汇报、谁提要求、谁承诺」的归属信息。结果会缓存，重复处理同一文件不再重算。")
            .font(.caption)
            .foregroundStyle(.secondary)

        switch readiness {
        case .ready:
            Label("已安装（\(ByteCountFormatter.string(fromByteCount: Diarizer.installedSize, countStyle: .file))）",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)

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
    @State private var probe: ProbeState = .idle
    @State private var hasStoredKey = false

    private enum ProbeState: Equatable {
        case idle, running, ok(String), failed(String)
    }

    var body: some View {
        Picker("服务商", selection: Binding(
            get: { settings.providerID },
            set: { id in
                settings.selectProvider(ProviderPreset.preset(id: id))
                key = ""
                hasStoredKey = settings.providerKeyExists
                probe = .idle
            }
        )) {
            ForEach(ProviderPreset.all) { Text($0.name).tag($0.id) }
        }

        TextField("接口地址", text: $settings.providerBaseURL,
                  prompt: Text("https://api.example.com/v1"))
            .font(.system(.callout, design: .monospaced))

        if let warning = OpenAICompatibleClient.securityWarning(for: settings.providerBaseURL) {
            Label(warning, systemImage: "lock.open.trianglebadge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.red)
        }

        if settings.provider.requiresKey {
            SecureField("API key", text: $key,
                        prompt: Text(hasStoredKey ? "已保存；输入新值可替换" : settings.provider.keyHint))
            HStack {
                Button(hasStoredKey ? "保存新的 API key" : "保存 API key") {
                    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    settings.providerKey = value
                    key = ""
                    hasStoredKey = true
                    probe = .idle
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasStoredKey {
                    Button("清除已保存的 API key", role: .destructive) {
                        settings.providerKey = nil; key = ""; hasStoredKey = false
                        probe = .idle
                    }
                }
            }
            .font(.caption)
            Text("密钥只会在点击保存时写入钥匙串。")
                .font(.caption).foregroundStyle(.secondary)
        }

        Picker("模型", selection: $settings.providerModel) {
            ForEach(settings.provider.models) { Text($0.label).tag($0.id) }
        }

        HStack {
            if settings.providerSupportsVision {
                Label("架构图等画面会作为图片传入", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("该模型不支持读图，画面只以 OCR 文字传入", systemImage: "text.alignleft")
                    .font(.caption).foregroundStyle(.secondary)
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
        .onAppear { hasStoredKey = settings.providerKeyExists }
    }

    /// One cheap round-trip, so a wrong URL or key surfaces here instead of
    /// after a three-minute transcription.
    private func runProbe() {
        probe = .running
        let client = OpenAICompatibleClient(
            baseURL: settings.providerBaseURL,
            apiKey: settings.providerKey,
            model: settings.providerModel,
            supportsVision: false,
            apiStyle: settings.provider.apiStyle,
            httpHeaders: settings.provider.httpHeaders
        )
        Task {
            let startedAt = Date()
            do {
                let result = try await client.completeDetailed(
                    system: "你是一个测试助手。", user: "回复两个字：可用", images: [])
                let context = TokenUsageContext(feature: "模型连接测试")
                TokenUsageContext.$current.withValue(context) {
                    TokenUsageLedger.record(
                        startedAt: startedAt, backend: settings.provider.name,
                        model: settings.providerModel,
                        inputTokens: result.inputTokens ?? 12,
                        outputTokens: result.outputTokens ?? TokenEstimator.count(result.text),
                        isEstimated: result.inputTokens == nil || result.outputTokens == nil,
                        status: .succeeded)
                }
                let reply = result.text
                probe = .ok("连接正常：\(reply.prefix(20))")
            } catch {
                let context = TokenUsageContext(feature: "模型连接测试")
                TokenUsageContext.$current.withValue(context) {
                    TokenUsageLedger.record(
                        startedAt: startedAt, backend: settings.provider.name,
                        model: settings.providerModel, inputTokens: 12,
                        outputTokens: 0, isEstimated: true, status: .failed, error: error)
                }
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

private enum ModelStatus: Equatable {
    case ready, missing

    static func check() -> ModelStatus {
        ToolLocator.modelPath() != nil && ToolLocator.vadModelPath() != nil ? .ready : .missing
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
        failed = false
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

        do {
            let existing = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size])
                as? NSNumber)?.int64Value ?? 0
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 || status == 206 else {
                throw URLError(.badServerResponse)
            }
            let isResuming = status == 206 && existing > 0
            let expectedBody = response.expectedContentLength
            let expectedTotal = expectedBody > 0
                ? expectedBody + (isResuming ? existing : 0) : -1

            if !isResuming { try? FileManager.default.removeItem(at: partial) }
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partial)
            if isResuming { try handle.seekToEnd() }
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            var written: Int64 = isResuming ? existing : 0
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
                        if expectedTotal > 0 {
                            progress = min(Double(written) / Double(expectedTotal), 1)
                            detail = String(format: "%@ %.0f / %.0f MB", label,
                                            mb, Double(expectedTotal) / 1_048_576)
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
            if expectedTotal > 0, written < expectedTotal {
                throw URLError(.dataLengthExceedsMaximum)
            }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            failed = true
            let saved = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size])
                as? NSNumber)?.int64Value ?? 0
            let suffix = saved > 0
                ? "；已保留 \(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file))，再次点击可续传"
                : ""
            detail = "\(label)下载失败：\(error.localizedDescription)\(suffix)"
        }
    }
}
