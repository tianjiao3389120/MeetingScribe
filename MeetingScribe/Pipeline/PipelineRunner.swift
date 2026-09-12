import Foundation
import Observation

/// Drives one media file through the whole pipeline and publishes progress.
@Observable
@MainActor
final class PipelineRunner {

    enum Stage: String, CaseIterable {
        case idle, probing, extractingAudio, transcribing, separatingSpeakers,
             extractingFrames, readingScreen, analyzing, reviewingIssues, done, failed

        var label: String {
            switch self {
            case .idle:               return "待机"
            case .probing:            return "读取文件"
            case .extractingAudio:    return "提取音轨"
            case .transcribing:       return "语音转录"
            case .separatingSpeakers: return "分离说话人"
            case .extractingFrames:   return "提取画面"
            case .readingScreen:      return "识别屏幕文字"
            case .analyzing:          return "生成纪要"
            case .reviewingIssues:    return "确认问题边界"
            case .done:               return "完成"
            case .failed:             return "失败"
            }
        }
    }

    private(set) var stage: Stage = .idle
    private(set) var progress: Double = 0
    private(set) var detail: String = ""
    private(set) var assets: MeetingAssets?
    private(set) var summary: String = ""
    private(set) var structuredSummary: StructuredMinutes?
    private(set) var usedSummaryFallback = false
    private(set) var historyWarning: String?
    private(set) var error: String?
    private(set) var isRunning = false
    private(set) var savedRecordID: UUID?
    private(set) var issueReviewReasons: [String] = []
    private var pendingReviewRecord: MeetingRecord?
    private var pendingReviewMaterials: [SupportingMaterial] = []

    /// True when transcription and screen extraction succeeded but the model
    /// call failed. The expensive work is still in `assets`, so the user can
    /// fix their key or switch provider and retry without redoing it.
    var canRetryAnalysis: Bool { assets != nil && summary.isEmpty }

    /// Whether this run skipped transcription by reusing a cached transcript.
    private(set) var usedCachedTranscript = false

    /// Set when speaker separation was requested but failed — surfaced as a
    /// notice rather than an error, since the summary is still usable.
    private(set) var speakerWarning: String?

    private var task: Task<Void, Never>?
    private var forceRetranscribe = false
    private var forceSpeakerSeparation = false
    private var pendingJobID: UUID?
    private var debugSession: PipelineDebugSession?
    private var processingStartedAt: Date?
    private var sourceDuration: TimeInterval = 0
    private var usedCachedDiarization = false

    var estimatedRemainingText: String? {
        guard let started = processingStartedAt,
              let total = ProcessingTimeHistory.estimatedTotal(for: sourceDuration) else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        let remaining = max(total - elapsed, 0)
        return remaining > 30 ? "根据本机历史，预计还需约 \(Self.durationText(remaining))" : "即将完成"
    }

    func cancel() {
        task?.cancel()
        PendingJobStore.clear(id: pendingJobID)
        PendingIssueReviewStore.clear()
        task = nil
        isRunning = false
        stage = .idle
        detail = "已取消"
        emitRunSummary(status: "已取消")
    }

    func run(url: URL, forceRetranscribe: Bool = false,
             forceSpeakerSeparation: Bool = false,
             recordedAt: Date? = nil,
             meetingGroupID: UUID? = nil,
             title: String? = nil, meetingContext: String = "",
             minutesTemplateID: String = MinutesTemplate.general.id,
             recognitionScenario: RecognitionScenario = .autoMultilingual,
             speakerCount: Int = 0,
             workspace: MeetingWorkspace? = nil,
             speakerNames: [Int: String] = [:], speakerRoles: [Int: SpeakerRole] = [:],
             customerName: String = "", projectName: String = "",
             tags: [String] = [], materials: [SupportingMaterial] = []) {
        task?.cancel()
        error = nil
        summary = ""
        structuredSummary = nil
        usedSummaryFallback = false
        assets = nil
        isRunning = true
        speakerWarning = nil
        historyWarning = nil
        savedRecordID = nil
        pendingReviewRecord = nil
        issueReviewReasons = []
        processingStartedAt = Date()
        sourceDuration = 0
        usedCachedDiarization = false
        configureDebugSession()
        self.forceRetranscribe = forceRetranscribe
        self.forceSpeakerSeparation = forceSpeakerSeparation
        let pendingJob = PendingMeetingJob(
            sourcePath: url.path, title: title ?? "", meetingContext: meetingContext,
            minutesTemplateID: minutesTemplateID,
            recognitionScenario: recognitionScenario,
            workspaceID: workspace?.id, customerName: customerName,
            projectName: projectName, tags: tags,
            materialPaths: materials.map { $0.sourceURL.path }, meetingGroupID: meetingGroupID)
        pendingJobID = pendingJob.id
        try? PendingJobStore.save(pendingJob)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.execute(url: url, title: title, meetingContext: meetingContext,
                                       recordedAt: recordedAt,
                                       meetingGroupID: meetingGroupID,
                                       minutesTemplateID: minutesTemplateID,
                                       recognitionScenario: recognitionScenario,
                                       speakerCount: speakerCount,
                                       workspace: workspace,
                                       speakerNames: speakerNames, speakerRoles: speakerRoles,
                                       customerName: customerName, projectName: projectName,
                                       tags: tags, materials: materials)
            } catch is CancellationError {
                self.stage = .idle
                self.detail = "已取消"
                PendingJobStore.clear(id: pendingJob.id)
                self.emitRunSummary(status: "已取消")
            } catch {
                self.stage = .failed
                self.error = error.localizedDescription
                self.emitRunSummary(status: "失败", extra: "错误：\(error.localizedDescription)")
            }
            if self.stage != .failed && self.stage != .idle {
                self.emitRunSummary(status: self.stage == .reviewingIssues ? "等待问题确认" : "成功")
            }
            self.isRunning = false
            PipelineDebugRegistry.install(nil)
        }
    }

    func run(imported package: ExternalTranscriptPackage,
             title: String? = nil, meetingGroupID: UUID? = nil, meetingContext: String = "",
             minutesTemplateID: String = MinutesTemplate.general.id,
             recognitionScenario: RecognitionScenario = .autoMultilingual,
             workspace: MeetingWorkspace? = nil,
             customerName: String = "", projectName: String = "",
             tags: [String] = [], materials: [SupportingMaterial] = []) {
        task?.cancel()
        error = nil
        summary = ""
        structuredSummary = nil
        usedSummaryFallback = false
        assets = nil
        isRunning = true
        speakerWarning = nil
        historyWarning = nil
        savedRecordID = nil
        pendingReviewRecord = nil
        issueReviewReasons = []
        processingStartedAt = Date()
        usedCachedDiarization = false
        configureDebugSession()
        usedCachedTranscript = true
        let sourcePaths = [package.transcriptURL, package.textURL, package.audioURL]
            .compactMap { $0?.path }
        let pendingJob = PendingMeetingJob(
            sourcePath: package.transcriptURL.path, title: title ?? "",
            meetingContext: meetingContext, minutesTemplateID: minutesTemplateID,
            recognitionScenario: recognitionScenario, workspaceID: workspace?.id,
            customerName: customerName, projectName: projectName, tags: tags,
            materialPaths: materials.map { $0.sourceURL.path }, sourcePaths: sourcePaths,
            meetingGroupID: meetingGroupID)
        pendingJobID = pendingJob.id
        try? PendingJobStore.save(pendingJob)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                self.stage = .probing
                self.progress = 1
                try await self.debugSession?.beginNode("读取外部逐字稿", input: """
                SRT：\(package.transcriptURL.path)
                TXT：\(package.textURL?.path ?? "<无>")
                音频：\(package.audioURL?.path ?? "<无>")
                """)
                self.detail = "读取外部逐字稿（\(package.transcript.segments.count) 段）"
                var related = [package.transcriptURL]
                if let textURL = package.textURL { related.append(textURL) }
                if let audioURL = package.audioURL { related.append(audioURL) }
                let duration = max(package.transcript.duration,
                                   package.metadata.declaredDuration ?? 0)
                self.sourceDuration = duration
                if let debug = self.debugSession {
                    let transcriptText = debug.writeText(
                        "imported-transcript.txt", package.transcript.timecodedText)
                    let transcriptJSON = (try? String(
                        data: JSONEncoder().encode(package.transcript), encoding: .utf8)) ?? "<编码失败>"
                    let transcriptJSONURL = debug.writeText(
                        "imported-transcript.json", transcriptJSON)
                    debug.endNode("读取外部逐字稿", output: """
                    分段数：\(package.transcript.segments.count)
                    时长：\(duration) 秒
                    文本：\(transcriptText?.path ?? "<写入失败>")
                    JSON：\(transcriptJSONURL?.path ?? "<写入失败>")
                    """)
                }
                let bundle = MeetingAssets(
                    sourceURL: package.transcriptURL,
                    sourceKind: .importedTranscript,
                    relatedSourceURLs: related,
                    meetingGroupID: meetingGroupID,
                    recordedAt: package.metadata.recordedAt
                        ?? MeetingDateResolver.recordedAt(for: package.transcriptURL),
                    customTitle: title,
                    meetingContext: meetingContext,
                    minutesTemplateID: minutesTemplateID,
                    recognitionScenario: recognitionScenario,
                    duration: duration,
                    transcript: package.transcript,
                    captures: [],
                    hasVideo: false,
                    diarization: nil,
                    materials: materials,
                    workspace: workspace,
                    customerName: customerName,
                    projectName: projectName,
                    tags: tags)
                self.assets = bundle
                try await self.analyze(bundle)
            } catch is CancellationError {
                self.stage = .idle
                self.detail = "已取消"
                PendingJobStore.clear(id: pendingJob.id)
                self.emitRunSummary(status: "已取消")
            } catch {
                self.stage = .failed
                self.error = error.localizedDescription
                self.emitRunSummary(status: "失败", extra: "错误：\(error.localizedDescription)")
            }
            if self.stage != .failed && self.stage != .idle {
                self.emitRunSummary(status: self.stage == .reviewingIssues ? "等待问题确认" : "成功")
            }
            self.isRunning = false
            PipelineDebugRegistry.install(nil)
        }
    }

    func restoreIssueReview(_ draft: PendingIssueReviewDraft,
                            materials: [SupportingMaterial]) {
        task?.cancel()
        pendingReviewRecord = draft.record
        pendingReviewMaterials = materials
        issueReviewReasons = draft.reasons
        summary = draft.record.summaryMarkdown
        structuredSummary = draft.record.structuredSummary
        savedRecordID = nil
        error = nil
        isRunning = false
        stage = .reviewingIssues
        progress = 1
        detail = "已恢复待确认的会议纪要"
    }

    /// Re-runs diarization with the current speaker-count setting while still
    /// reusing the cached transcript. Useful when automatic clustering guessed
    /// poorly; transcription is not paid for again.
    func rerunSpeakerSeparation(speakerCount: Int = 0) {
        guard let bundle = assets, !isRunning else { return }
        run(url: bundle.sourceURL, forceSpeakerSeparation: true,
            recordedAt: bundle.recordedAt,
            meetingGroupID: bundle.meetingGroupID,
            title: bundle.title, meetingContext: bundle.meetingContext,
            minutesTemplateID: bundle.minutesTemplateID,
            recognitionScenario: bundle.recognitionScenario,
            speakerCount: speakerCount,
            workspace: bundle.workspace,
            speakerNames: bundle.diarization?.names ?? [:],
            speakerRoles: bundle.diarization?.roles ?? [:],
            tags: bundle.tags, materials: bundle.materials)
    }

    /// Re-runs only the model call, reusing the existing transcript and captures.
    func retryAnalysis() {
        guard let bundle = assets, !isRunning else { return }
        task?.cancel()
        savedRecordID = nil
        error = nil
        isRunning = true

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.analyze(bundle)
            } catch is CancellationError {
                self.stage = .failed
                self.detail = "已取消"
            } catch {
                self.stage = .failed
                self.error = error.localizedDescription
            }
            self.isRunning = false
        }
    }

    func regenerate(withFeedback feedback: String) {
        guard var bundle = assets, !isRunning else { return }
        let value = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        bundle.meetingContext = [bundle.meetingContext, "重新生成修改要求：\(value)"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        assets = bundle
        retryAnalysis()
    }

    func analyzeEditedTranscript(record: MeetingRecord, transcript: Transcript,
                                 workspace: MeetingWorkspace?,
                                 materials: [SupportingMaterial]) {
        task?.cancel()
        error = nil; summary = ""; structuredSummary = nil
        usedSummaryFallback = false; isRunning = true
        let bundle = MeetingAssets(
            sourceURL: record.sourceURL,
            sourceKind: MeetingAssets.SourceKind(rawValue: record.sourceKind ?? "")
                ?? .recordedMedia,
            relatedSourceURLs: (record.relatedSourcePaths ?? []).map(URL.init(fileURLWithPath:)),
            meetingGroupID: record.meetingGroupID ?? record.id,
            recordedAt: record.createdAt, customTitle: record.title,
            meetingContext: record.meetingContext ?? "",
            minutesTemplateID: record.minutesTemplateID ?? MinutesTemplate.general.id,
            duration: record.duration,
            transcript: transcript, captures: [], hasVideo: false,
            diarization: nil, materials: materials, workspace: workspace,
            customerName: record.customerName ?? "",
            projectName: record.projectName ?? "",
            tags: record.tags ?? [])
        assets = bundle
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.analyze(bundle) }
            catch is CancellationError { self.stage = .idle; self.detail = "已取消" }
            catch { self.stage = .failed; self.error = error.localizedDescription }
            self.isRunning = false
        }
    }

    /// Applies names enrolled from this meeting before regenerating the
    /// summary, so the current result benefits immediately rather than only
    /// future recordings.
    func applySpeakerNamesAndRegenerate(_ names: [Int: String], roles: [Int: SpeakerRole]) {
        guard var bundle = assets, var diarization = bundle.diarization else { return }
        diarization.names.merge(names) { _, new in new }
        diarization.roles = roles.filter { $0.value.isSpecified }
        bundle.diarization = diarization
        assets = bundle
        retryAnalysis()
    }

    func applyRecognitionMemoryAndRegenerate() {
        guard var bundle = assets, !isRunning else { return }
        bundle.transcript = RecognitionMemoryStore.apply(
            to: bundle.transcript, workspaceID: bundle.workspace?.id)
        assets = bundle
        retryAnalysis()
    }

    private func execute(url: URL, title: String?, meetingContext: String,
                         recordedAt: Date?,
                         meetingGroupID: UUID?,
                         minutesTemplateID: String,
                         recognitionScenario: RecognitionScenario,
                         speakerCount: Int,
                         workspace: MeetingWorkspace?,
                         speakerNames: [Int: String], speakerRoles: [Int: SpeakerRole],
                         customerName: String, projectName: String,
                         tags: [String], materials: [SupportingMaterial]) async throws {
        let settings = Settings.shared
        let learningContext = ([meetingContext, workspace?.name, workspace?.context]
            + materials.prefix(3).map(\.extractedText)).compactMap { $0 }.joined(separator: " ")
        let learnedVocabulary = RecognitionMemoryStore.prompt(
            workspaceID: workspace?.id, context: learningContext)
        let extractor = MediaExtractor(url: url)
        let transcriptionPrompt = Self.transcriptionPrompt(
            scenario: recognitionScenario,
            priorityVocabulary: learnedVocabulary,
            glossary: settings.glossary,
            materials: materials)

        stage = .probing
        progress = 0
        try await debugSession?.beginNode("读取文件", input: """
        输入文件：\(url.path)
        识别场景：\(recognitionScenario.displayName)
        正式项目：\(workspace.map { "\($0.name)（\($0.id)）" } ?? "<无>")
        会议标签：\(tags.isEmpty ? "<空>" : tags.joined(separator: "、"))
        """)
        let info = try await extractor.probe()
        sourceDuration = info.duration
        guard info.hasAudio else { throw MediaExtractor.Failure.noAudioTrack }
        detail = "时长 \(TranscriptSegment.humanDuration(info.duration))" + (info.hasVideo ? "，含画面" : "")
        debugSession?.endNode("读取文件", output: """
        时长：\(info.duration) 秒
        包含音频：\(info.hasAudio)
        包含视频：\(info.hasVideo)
        """)

        // --- transcription and diarization ---------------------------------
        let transcriptKey = TranscriptCache.key(for: url,
                                                language: recognitionScenario.whisperLanguage,
                                                glossary: transcriptionPrompt)
        let wantsSpeakers = Diarizer.readiness().isReady
        let speakerKey = wantsSpeakers
            ? TranscriptCache.key(for: url,
                                  language: "speakers-\(speakerCount)",
                                  glossary: "",
                                  version: TranscriptCache.diarizationVersion)
            : nil

        var transcript: Transcript?
        if !forceRetranscribe, let transcriptKey, let cached = TranscriptCache.load(key: transcriptKey) {
            let metadata = TranscriptCache.metadata(key: transcriptKey)
            debugSession?.cache("语音转录", hit: true,
                                detail: "缓存键：\(transcriptKey)\n文件：\(metadata?.path ?? "<未知>")\n生成时间：\(metadata?.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "<未知>")\n大小：\(metadata?.bytes ?? 0) 字节\n分段数：\(cached.segments.count)\n跳过引擎：Whisper")
            try await debugSession?.beginNode("语音转录", input: "命中转录缓存：\(transcriptKey)")
            transcript = cached
            stage = .transcribing
            progress = 1
            detail = "复用已缓存的转录结果（\(cached.segments.count) 段）"
            usedCachedTranscript = true
            let textURL = debugSession?.writeText("transcript-cached.txt", cached.timecodedText)
            debugSession?.endNode("语音转录", output: """
            复用缓存：是
            分段数：\(cached.segments.count)
            文本：\(textURL?.path ?? "<写入失败>")
            """)
        } else {
            let reason = forceRetranscribe ? "用户要求重新转录"
                : (transcriptKey == nil ? "无法生成缓存键" : "缓存不存在、损坏或算法版本已变化")
            debugSession?.cache("语音转录", hit: false, detail: "原因：\(reason)\n缓存键：\(transcriptKey ?? "<无>")")
        }

        var diarization: Diarization?
        if wantsSpeakers, !forceRetranscribe, !forceSpeakerSeparation, let speakerKey,
           var cached = DiarizationCache.load(key: speakerKey) {
            // Names are derived state. Re-match on every cache read so profile
            // enrolment, rename and deletion take effect without re-diarizing.
            cached.names = VoiceProfileStore.match(embeddings: cached.embeddings)
            diarization = cached
            usedCachedDiarization = true
            let metadata = DiarizationCache.metadata(key: speakerKey)
            debugSession?.cache("声纹分离", hit: true,
                                detail: "缓存键：\(speakerKey)\n文件：\(metadata?.path ?? "<未知>")\n生成时间：\(metadata?.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "<未知>")\n大小：\(metadata?.bytes ?? 0) 字节\n说话片段：\(cached.segments.count)\n跳过引擎：声纹模型")
        } else if wantsSpeakers {
            let reason = forceRetranscribe || forceSpeakerSeparation ? "用户要求重新计算"
                : (speakerKey == nil ? "无法生成缓存键" : "缓存不存在、损坏或算法版本已变化")
            debugSession?.cache("声纹分离", hit: false, detail: "原因：\(reason)\n缓存键：\(speakerKey ?? "<无>")")
        }

        // Audio is only needed for work that isn't already cached.
        let needsAudio = transcript == nil || (wantsSpeakers && diarization == nil)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-\(UUID().uuidString)")
        defer {
            if !settings.keepIntermediates { try? FileManager.default.removeItem(at: work) }
        }

        var audioURL: URL?
        var debugAudioURL: URL?
        if needsAudio {
            usedCachedTranscript = transcript != nil
            stage = .extractingAudio
            progress = 0
            detail = "正在提取音轨 0%"
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let wav = work.appendingPathComponent("audio.wav")
            try await debugSession?.beginNode("音频提取", input: """
            输入文件：\(url.path)
            输出格式：16 kHz / 单声道 / PCM WAV
            临时输出：\(wav.path)
            """)
            let audioDebug = debugSession
            try await extractor.extractAudio(to: wav) { [weak self] fraction in
                audioDebug?.progressPercent("音频提取", label: "提取进度", fraction: fraction)
                Task { @MainActor in
                    guard self?.stage == .extractingAudio else { return }
                    self?.progress = fraction
                    self?.detail = String(format: "正在提取音轨 %.0f%%", fraction * 100)
                }
            }
            try Task.checkCancellation()
            audioURL = wav
            let saved = debugSession?.copyFile(wav, name: "audio.wav")
            debugAudioURL = saved
            debugSession?.endNode("音频提取", output: "音频文件：\(saved?.path ?? wav.path)")
        }

        if transcript == nil, let audioURL {
            usedCachedTranscript = false
            stage = .transcribing
            progress = 0
            detail = "正在加载语音模型并开始转录…"
            RecognitionMemoryStore.recordPromptUsage(
                workspaceID: workspace?.id, context: learningContext)
            let transcriber = Transcriber(audioURL: audioURL,
                                          language: recognitionScenario.whisperLanguage,
                                          glossary: transcriptionPrompt,
                                          performance: settings.transcriptionPerformance)
            try await debugSession?.beginNode("语音转录", input: """
            音频文件：\(debugAudioURL?.path ?? audioURL.path)
            语言：\(recognitionScenario.whisperLanguage)
            初始提示词：\n\(transcriptionPrompt.isEmpty ? "<空>" : transcriptionPrompt)
            """)
            let transcriptionDebug = debugSession
            let raw = try await transcriber.run { [weak self] seconds, _ in
                transcriptionDebug?.transcriptProgress(
                    "语音转录", seconds: seconds, duration: info.duration)
                Task { @MainActor in
                    guard let self else { return }
                    self.progress = min(seconds / max(info.duration, 1), 1)
                    self.detail = "已转录 \(TranscriptSegment.timecode(seconds)) / \(TranscriptSegment.timecode(info.duration))"
                }
            }
            try Task.checkCancellation()
            let fresh = RecognitionMemoryStore.apply(to: raw, workspaceID: workspace?.id)
            if let transcriptKey { TranscriptCache.save(fresh, key: transcriptKey) }
            transcript = fresh
            if let debug = debugSession {
                let textURL = debug.writeText("transcript.txt", fresh.timecodedText)
                let jsonText = (try? String(
                    data: JSONEncoder().encode(fresh), encoding: .utf8)) ?? "<编码失败>"
                let jsonURL = debug.writeText("transcript.json", jsonText)
                debug.endNode("语音转录", output: """
                分段数：\(fresh.segments.count)
                文本：\(textURL?.path ?? "<写入失败>")
                JSON：\(jsonURL?.path ?? "<写入失败>")
                """)
            }
        }

        // Silent or music-only input yields nothing to summarise; fail here
        // instead of spending a model call on an empty timeline.
        guard let transcript, !transcript.segments.isEmpty else { throw Failure.noSpeech }

        if wantsSpeakers, diarization == nil, let audioURL {
            stage = .separatingSpeakers
            progress = 0
            detail = "分析声纹特征…"
            do {
                try await debugSession?.beginNode("声纹分离", input: """
                音频文件：\(audioURL.path)
                预期说话人数：\(speakerCount == 0 ? "自动" : String(speakerCount))
                """)
                let diarizationDebug = debugSession
                let result = try await Diarizer.run(
                    audioURL: audioURL,
                    speakerCount: speakerCount
                ) { [weak self] fraction in
                    diarizationDebug?.progressPercent(
                        "声纹分离", label: "分析进度", fraction: fraction)
                    Task { @MainActor in
                        self?.progress = fraction
                        self?.detail = String(format: "分离说话人 %.0f%%", fraction * 100)
                    }
                }
                if let speakerKey { DiarizationCache.save(result, key: speakerKey) }
                diarization = result
                debugSession?.endNode("声纹分离", output: """
                说话片段：\(result.segments.count)
                声纹数量：\(result.embeddings.count)
                """)
            } catch {
                debugSession?.endNode("声纹分离", output: "失败：\(error.localizedDescription)")
                // Speaker labels are an enhancement; losing them should not
                // cost the user the transcript they already paid for.
                speakerWarning = "说话人分离失败，纪要将不含说话人信息：\(error.localizedDescription)"
            }
            try Task.checkCancellation()
        }

        // --- screen -------------------------------------------------------
        var captures: [ScreenCapture] = []
        if info.hasVideo, settings.frameDensity != .off {
            stage = .extractingFrames
            progress = 0
            let density = settings.frameDensity
            try await debugSession?.beginNode("提取画面", input: """
            输入文件：\(url.path)
            采样密度：\(density.displayName)
            采样间隔：\(density.interval) 秒
            最大画面数：\(density.maxFrames)
            差异阈值：\(density.distinctness)
            """)
            let frameDebug = debugSession
            captures = try await extractor.extractFrames(
                every: density.interval,
                maxFrames: density.maxFrames,
                distinctnessThreshold: density.distinctness
            ) { [weak self] value in
                frameDebug?.progressPercent("提取画面", label: "扫描进度", fraction: value)
                Task { @MainActor in
                    self?.progress = value
                    self?.detail = "扫描画面变化…"
                }
            }
            try Task.checkCancellation()
            if let debug = debugSession {
                var framePaths: [String] = []
                for capture in captures {
                    if let saved = debug.writePNG(
                        capture.image, name: String(
                            format: "frame-%04d-%.1fs.png", capture.id, capture.time)) {
                        framePaths.append("\(saved.path)（\(capture.image.width)x\(capture.image.height)）")
                    }
                }
                debug.endNode("提取画面", output: """
                保留画面：\(captures.count)
                文件：\n\(framePaths.isEmpty ? "<空>" : framePaths.joined(separator: "\n"))
                """)
            }

            detail = "保留 \(captures.count) 个不同画面"
        }

        if var identified = diarization {
            identified.names.merge(speakerNames) { _, saved in saved }
            identified.roles = speakerRoles.filter { $0.value.isSpecified }
            diarization = identified
        }

        let bundle = MeetingAssets(sourceURL: url,
                                   meetingGroupID: meetingGroupID,
                                   recordedAt: recordedAt
                                       ?? MeetingDateResolver.recordedAt(for: url),
                                   customTitle: title,
                                   meetingContext: meetingContext,
                                   minutesTemplateID: minutesTemplateID,
                                   recognitionScenario: recognitionScenario,
                                   duration: info.duration,
                                   transcript: transcript,
                                   captures: captures,
                                   hasVideo: info.hasVideo,
                                   diarization: diarization,
                                   materials: materials,
                                   workspace: workspace,
                                   customerName: customerName,
                                   projectName: projectName,
                                   tags: tags)
        // Publish before analysing: if the model call fails, the transcript and
        // captures survive and `retryAnalysis()` can reuse them.
        assets = bundle

        try await analyze(bundle)
    }

    static func transcriptionPrompt(scenario: RecognitionScenario,
                                    priorityVocabulary: String = "", glossary: String,
                                    materials: [SupportingMaterial]) -> String {
        let materialContext = materials.prefix(3).map {
            "\($0.name)：\($0.extractedText.replacingOccurrences(of: "\n", with: " ").prefix(60))"
        }.joined(separator: "；")
        // whisper.cpp keeps only the beginning of its initial prompt. Put explicit
        // learned corrections first, then the user's vocabulary, so a long scenario
        // hint can never push a critical product name out of the 170-character budget.
        return [priorityVocabulary, glossary, materialContext, scenario.transcriptionHint]
            .map(cleanWhisperPromptComponent)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func cleanWhisperPromptComponent(_ raw: String) -> String {
        raw.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let content = trimmed.components(separatedBy: " #").first ?? trimmed
            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }.joined(separator: "，")
    }

    private func analyze(_ originalBundle: MeetingAssets) async throws {
        let context = TokenUsageContext(
            feature: "生成会议纪要", customer: originalBundle.customerName,
            project: originalBundle.projectName, meetingID: originalBundle.meetingGroupID,
            meetingTitle: originalBundle.title)
        try await TokenUsageContext.$current.withValue(context) {
            try await analyzeWithUsageContext(originalBundle)
        }
    }

    private func analyzeWithUsageContext(_ originalBundle: MeetingAssets) async throws {
        stage = .analyzing
        progress = 0
        detail = ""

        var bundle = try await addAdaptiveScreenEvidence(to: originalBundle)
        if var stats = bundle.adaptiveScreenReviewStats {
            stats.framesSentToModel = Analyzer.screenFramesSentToModel(
                assets: bundle, settings: Settings.shared).count
            bundle.adaptiveScreenReviewStats = stats
        }
        assets = bundle

        let analyzer = Analyzer(assets: bundle, settings: Settings.shared)
        let result = try await analyzer.run { [weak self] message in
            Task { @MainActor in self?.detail = message }
        }
        finishTimingSample()
        var generationUsage = result.usage
        let adaptiveCandidates = AdaptiveFramePlanner.candidateTimeline(from: originalBundle.transcript)
        if originalBundle.hasVideo, originalBundle.sourceKind == .recordedMedia,
           !adaptiveCandidates.isEmpty {
            let planned = bundle.adaptiveScreenReviewStats?.plannedNodes ?? 0
            generationUsage.phases.insert(
                GenerationUsage.estimatedPhase(
                    name: "画面节点规划", input: adaptiveCandidates,
                    output: "规划 \(planned) 个补充画面节点"), at: 0)
        }
        var trackedStructured = result.structured
        var associationReviewReasons: [String] = []
        if var structured = trackedStructured {
            let confirmedIssues = bundle.workspace.map {
                (try? ProjectLedgerStore.load().issues(for: $0.id)) ?? []
            } ?? []
            do {
                let association = try await IssueAssociationService(settings: Settings.shared)
                    .associate(structured, workspaceID: bundle.workspace?.id)
                structured = association.minutes
                associationReviewReasons = association.reviewReasons
                if association.phase.calls > 0 { generationUsage.phases.append(association.phase) }
            } catch {
                debugSession?.nodeWarning("问题关联",
                    detail: "独立关联失败，将使用本地保守匹配：\(error.localizedDescription)")
                associationReviewReasons = ["问题关联未完成，已使用本地保守匹配"]
            }
            IssueTracking.prepare(&structured, confirmedIssues: confirmedIssues)
            trackedStructured = structured
        }
        let renderedMarkdown = trackedStructured.map(StructuredMinutesRenderer.markdown) ?? result.markdown
        summary = renderedMarkdown
        structuredSummary = trackedStructured
        usedSummaryFallback = result.usedFallback
        if var stats = bundle.adaptiveScreenReviewStats {
            stats.citedScreenEvidence = Analyzer.screenCitationCount(in: trackedStructured)
            bundle.adaptiveScreenReviewStats = stats
            assets?.adaptiveScreenReviewStats = stats
        }
        if let structured = trackedStructured {
            let evidenceGroups = structured.issues.map(\.evidence)
                + structured.requirements.map(\.evidence)
                + structured.actionItems.map(\.evidence)
                + structured.agreements.map(\.evidence)
                + structured.afterMeeting.map(\.evidence)
                + structured.uncertainties.map(\.evidence)
            let withoutEvidence = evidenceGroups.filter(\.isEmpty).count
            let phaseLines = generationUsage.phases.map {
                "\($0.name)：输入 \($0.inputTokens) · 输出 \($0.outputTokens) · 调用 \($0.calls)"
            }.joined(separator: "\n")
            debugSession?.qualitySummary("""
            结构化 JSON：解析成功
            问题：\(structured.issues.count)
            需求：\(structured.requirements.count)
            待办：\(structured.actionItems.count)
            不确定项：\(structured.uncertainties.count)
            屏幕引用：\(Analyzer.screenCitationCount(in: structured))/\(bundle.adaptiveScreenReviewStats?.framesSentToModel ?? 0)
            无证据条目：\(withoutEvidence)
            Token 估算分项：
            \(phaseLines)
            """)
        } else {
            debugSession?.qualitySummary("结构化 JSON：解析失败，已保留模型原始输出")
        }

        let resolvedTitle = MeetingTitleResolver.resolve(
            requestedTitle: bundle.title,
            sourceURL: bundle.sourceURL,
            generatedTitle: trackedStructured?.title)
        if resolvedTitle != bundle.title {
            var updatedAssets = bundle
            updatedAssets.customTitle = resolvedTitle
            assets = updatedAssets
        }

        let settings = Settings.shared
        let model: String
        switch settings.backend {
        case .codexCLI: model = "Codex CLI"
        case .claudeCLI: model = "claude CLI"
        case .openAICompatible: model = settings.providerModel
        }
        let record = MeetingRecord(
            createdAt: bundle.recordedAt,
            title: resolvedTitle,
            sourcePath: bundle.sourceURL.path,
            duration: bundle.duration,
            backend: settings.backend == .openAICompatible
                ? settings.provider.name : settings.backend.displayName,
            model: model,
            summaryMarkdown: renderedMarkdown,
            structuredSummary: trackedStructured,
            transcript: bundle.transcript,
            speakerNames: bundle.diarization?.names ?? [:],
            usedSummaryFallback: result.usedFallback,
            speakerRoles: bundle.diarization?.roles ?? [:],
            workspaceID: bundle.workspace?.id,
            customerName: bundle.customerName,
            projectName: bundle.projectName,
            tags: bundle.tags,
            materials: bundle.materials.map {
                MaterialReference(name: $0.name, kind: $0.kind,
                                  sourcePath: $0.sourceURL.path)
            })
        var storedRecord = record
        storedRecord.sourceKind = bundle.sourceKind.rawValue
        storedRecord.relatedSourcePaths = bundle.relatedSourceURLs.map(\.path)
        storedRecord.meetingContext = bundle.meetingContext
        storedRecord.minutesTemplateID = bundle.minutesTemplateID
        storedRecord.actionStatusSuggestions = nil
        storedRecord.adaptiveScreenReviewStats = bundle.adaptiveScreenReviewStats
        storedRecord.generationUsage = generationUsage
        storedRecord.meetingGroupID = bundle.meetingGroupID ?? storedRecord.id
        let reviewRisks = (trackedStructured.map { IssuePreflight.risks(in: $0.issues) } ?? [])
            + associationReviewReasons
        let isHeadless = CommandLine.arguments.contains("--regenerate-record")
        if !isHeadless, trackedStructured?.issues.isEmpty == false,
           Settings.shared.alwaysReviewIssues || !reviewRisks.isEmpty {
            pendingReviewRecord = storedRecord
            pendingReviewMaterials = bundle.materials
            issueReviewReasons = reviewRisks
            stage = .reviewingIssues
            progress = 1
            detail = reviewRisks.isEmpty ? "请确认问题后生成最终纪要" : "检测到问题边界可能需要确认"
            do {
                try PendingIssueReviewStore.save(.init(
                    record: storedRecord,
                    materialPaths: bundle.materials.map { $0.sourceURL.path },
                    reasons: reviewRisks))
            } catch {
                historyWarning = "待确认纪要暂存失败，请不要在确认前退出应用：\(error.localizedDescription)"
            }
            return
        }
        _ = persist(storedRecord, materials: bundle.materials)

        stage = .done
        progress = 1
        detail = "完成"
        emitRunSummary(status: "成功（问题已确认并保存）")
    }

    func finalizeIssueReview(_ issues: [StructuredMinutes.Issue]) {
        guard var record = pendingReviewRecord, var structured = record.structuredSummary else { return }
        structured.issues = issues
        let validIDs = Set(issues.compactMap(\.trackingID))
        for index in structured.actionItems.indices {
            if let issueID = structured.actionItems[index].issueID,
               !validIDs.contains(issueID) {
                structured.actionItems[index].issueID = nil
            }
        }
        record.structuredSummary = structured
        record.summaryMarkdown = StructuredMinutesRenderer.markdown(from: structured)
        structuredSummary = structured
        summary = record.summaryMarkdown
        guard persist(record, materials: pendingReviewMaterials) else {
            stage = .reviewingIssues
            detail = "纪要已生成，但尚未保存到资料库；请重试确认。"
            return
        }
        PendingIssueReviewStore.clear()
        pendingReviewRecord = nil
        pendingReviewMaterials = []
        issueReviewReasons = []
        stage = .done
        progress = 1
        detail = "完成"
    }

    private func finishTimingSample() {
        guard debugSession == nil, let started = processingStartedAt, sourceDuration > 0 else { return }
        let elapsed = Date().timeIntervalSince(started)
        ProcessingTimeHistory.record(mediaDuration: sourceDuration,
                                     processingDuration: max(elapsed, 1))
        processingStartedAt = nil
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded()), 1)
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }

    private func configureDebugSession() {
        let settings = Settings.shared
        debugSession = settings.pipelineDebugEnabled
            ? try? PipelineDebugSession(pausesAtNodeStart: settings.pipelineDebugPauseAtNodeStart)
            : nil
        PipelineDebugRegistry.install(debugSession)
    }

    private func emitRunSummary(status: String, extra: String = "") {
        let cache = "转录\(usedCachedTranscript ? "命中" : "未命中")、声纹\(usedCachedDiarization ? "命中" : "未命中")"
        let screen = assets?.adaptiveScreenReviewStats?.summary ?? "未执行"
        debugSession?.runSummary(status: status, cache: cache, screen: screen, extra: extra)
    }

    @discardableResult
    private func persist(_ record: MeetingRecord, materials: [SupportingMaterial]) -> Bool {
        do {
            try MeetingHistoryStore.save(record, materialSources: materials)
            savedRecordID = record.id
        } catch {
            historyWarning = "历史记录保存失败：\(error.localizedDescription)"
            return false
        }
        PendingJobStore.clear(id: pendingJobID)
        do {
            try ProjectLedgerStore.prepareProposals(for: record)
            try ProjectLedgerStore.applyRetrievalProfiles(for: record)
        } catch {
            historyWarning = "会议已保存，但项目问题建议生成失败：\(error.localizedDescription)"
        }
        return true
    }

    /// A best-effort second look at the screen. Planning or image extraction
    /// must never turn a usable transcript into a failed meeting.
    private func addAdaptiveScreenEvidence(to bundle: MeetingAssets) async throws -> MeetingAssets {
        guard bundle.hasVideo, bundle.sourceKind == .recordedMedia,
              !bundle.adaptiveScreenReviewCompleted,
              !bundle.transcript.segments.isEmpty else { return bundle }
        func completed(_ value: MeetingAssets) -> MeetingAssets {
            var copy = value
            copy.adaptiveScreenReviewCompleted = true
            return copy
        }
        var reviewStats = AdaptiveScreenReviewStats()
        guard !AdaptiveFramePlanner.candidateTimeline(from: bundle.transcript).isEmpty else {
            var updated = bundle
            updated.adaptiveScreenReviewStats = reviewStats
            return completed(updated)
        }
        detail = "分析逐字稿，寻找需要画面补证的节点…"
        do {
            let requests = try await AdaptiveFramePlanner(settings: Settings.shared)
                .plan(transcript: bundle.transcript, duration: bundle.duration)
            reviewStats.plannedNodes = requests.count
            guard !requests.isEmpty else {
                var updated = bundle
                updated.adaptiveScreenReviewStats = reviewStats
                return completed(updated)
            }

            // Look just before, at, and just after the requested moment. Drop
            // probes already covered by the regular sampler.
            let existingTimes = bundle.captures.map(\.time)
            let probes = requests.flatMap { request in
                [request.seconds - request.radius, request.seconds, request.seconds + request.radius]
                    .map { (time: min(max($0, 0), bundle.duration), reason: request.reason) }
            }.filter { probe in
                !existingTimes.contains(where: { abs($0 - probe.time) < 1 })
            }
            reviewStats.requestedProbes = min(probes.count, 18)
            guard !probes.isEmpty else {
                var updated = bundle
                updated.adaptiveScreenReviewStats = reviewStats
                return completed(updated)
            }

            detail = "补充抽取 \(requests.count) 个关键节点的画面…"
            let nextID = (bundle.captures.map(\.id).max() ?? -1) + 1
            let selectedProbes = Array(probes.prefix(18))
            try await debugSession?.beginNode("补充提取画面", input: selectedProbes.map {
                "时间：\($0.time) 秒；原因：\($0.reason)"
            }.joined(separator: "\n"))
            let adaptiveDebug = debugSession
            let extracted = try await MediaExtractor(url: bundle.sourceURL)
                .extractFrames(at: selectedProbes, startingID: nextID) { value in
                    adaptiveDebug?.progressPercent(
                        "补充提取画面", label: "扫描进度", fraction: value)
                }
            if let debug = debugSession {
                var adaptivePaths: [String] = []
                for capture in extracted {
                    if let url = debug.writePNG(
                        capture.image, name: "adaptive-frame-\(capture.id).png") {
                        adaptivePaths.append(url.path)
                    }
                }
                debug.endNode("补充提取画面", output: """
                抽取画面：\(extracted.count)
                文件：\n\(adaptivePaths.isEmpty ? "<空>" : adaptivePaths.joined(separator: "\n"))
                """)
            }
            let annotated: [ScreenCapture]
            if Self.backendSupportsVision(Settings.shared) {
                annotated = extracted
            } else {
                try await debugSession?.beginNode("补充 OCR", input: """
                原因：当前模型后端不支持图片输入
                画面数量：\(extracted.count)
                """)
                annotated = await TextRecognizer.annotate(extracted) { value in
                    adaptiveDebug?.progressPercent("补充 OCR", label: "识别进度", fraction: value)
                }
                if let debug = debugSession {
                    let adaptiveOCR = annotated.map {
                        "===== 画面 \($0.id) =====\n\($0.recognizedText.joined(separator: "\n"))"
                    }.joined(separator: "\n\n")
                    let adaptiveOCRURL = debug.writeText("adaptive-ocr.txt", adaptiveOCR)
                    debug.endNode("补充 OCR", output: "OCR 文件：\(adaptiveOCRURL?.path ?? "<写入失败>")")
                }
            }
            // The regular scan is only a change index and is never sent to a
            // vision backend. Comparing probes with it would incorrectly drop
            // the very evidence frames requested by the planner. Deduplicate
            // only inside this targeted probe set.
            let useful = Self.distinctEvidenceFrames(annotated)
            if let debug = debugSession {
                let acceptedIDs = Set(useful.map(\.id))
                let lines = annotated.map { capture in
                    let decision: String
                    if acceptedIDs.contains(capture.id) {
                        decision = "保留：定向事件中的有效画面"
                    } else {
                        let duplicate = useful.first {
                            PerceptualHash.distance($0.fingerprint, capture.fingerprint) < 8
                        }
                        decision = duplicate.map { "剔除：与画面 #\($0.id) 感知哈希相似" }
                            ?? "剔除：没有新增像素或 OCR 文本"
                    }
                    return "#\(capture.id) · \(capture.timecode) · \(capture.evidenceReason ?? "<无原因>") · \(decision)"
                }
                debug.imageSelection("探针内部去重：\n" + lines.joined(separator: "\n"))
            }

            reviewStats.extractedFrames = extracted.count
            reviewStats.framesWithOCR = annotated.filter { !$0.recognizedText.isEmpty }.count
            reviewStats.acceptedFrames = useful.count

            var updated = bundle
            updated.captures.append(contentsOf: useful)
            updated.captures.sort { $0.time < $1.time }
            updated.adaptiveScreenReviewStats = reviewStats
            return completed(updated)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            detail = "补充画面失败，继续使用已提取内容…"
            var updated = bundle
            updated.adaptiveScreenReviewStats = reviewStats
            return completed(updated)
        }
    }

    static func backendSupportsVision(_ settings: Settings) -> Bool {
        switch settings.backend {
        case .codexCLI: return true
        case .claudeCLI: return false
        case .openAICompatible: return settings.providerSupportsVision
        }
    }

    /// Keeps only visually distinct targeted probes. This prevents a single
    /// event's before/at/after triplet from consuming the final image budget.
    static func distinctEvidenceFrames(_ candidates: [ScreenCapture]) -> [ScreenCapture] {
        var accepted: [ScreenCapture] = []
        var acceptedText = Set<String>()
        for candidate in candidates {
            let visuallyNew = !accepted.contains {
                PerceptualHash.distance($0.fingerprint, candidate.fingerprint) < 8
            }
            let hasNewText = candidate.recognizedText.contains {
                !acceptedText.contains($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if visuallyNew || hasNewText {
                accepted.append(candidate)
                acceptedText.formUnion(candidate.recognizedText.map {
                    $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                })
            }
        }
        return accepted
    }

    enum Failure: LocalizedError {
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .noSpeech:
                return "没有识别到任何语音内容。请确认文件包含说话声，且设置里的识别语言正确。"
            }
        }
    }

    /// Writes the summary and transcript next to the source file.
    @discardableResult
    func saveOutputs(to directory: URL? = nil) throws -> URL {
        guard let assets else { throw CocoaError(.fileNoSuchFile) }
        let destination = directory ?? assets.sourceURL.deletingLastPathComponent()
        let base = assets.title

        let summaryURL = destination.appendingPathComponent("\(base) 纪要.md")
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)

        let transcriptURL = destination.appendingPathComponent("\(base) 逐字稿.txt")
        try assets.transcript.timecodedText.write(to: transcriptURL, atomically: true, encoding: .utf8)

        if let structuredSummary {
            let data = try JSONEncoder.pretty.encode(structuredSummary)
            try data.write(to: destination.appendingPathComponent("\(base) 纪要.json"),
                           options: .atomic)
        }

        return summaryURL
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
