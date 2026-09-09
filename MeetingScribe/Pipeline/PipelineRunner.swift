import Foundation
import Observation

/// Drives one media file through the whole pipeline and publishes progress.
@Observable
@MainActor
final class PipelineRunner {
    let debugSession = PipelineDebugSession()

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

    func cancel() {
        debugSession.resume()
        task?.cancel()
        PendingJobStore.clear(id: pendingJobID)
        task = nil
        isRunning = false
        stage = .idle
        detail = "已取消"
    }

    func run(url: URL, forceRetranscribe: Bool = false,
             forceSpeakerSeparation: Bool = false,
             recordedAt: Date? = nil,
             title: String? = nil, meetingContext: String = "",
             minutesTemplateID: String = MinutesTemplate.general.id,
             recognitionScenario: RecognitionScenario = .autoMultilingual,
             speakerCount: Int = 0,
             workspace: MeetingWorkspace? = nil,
             speakerNames: [Int: String] = [:], speakerRoles: [Int: SpeakerRole] = [:],
             customerName: String = "", projectName: String = "",
             tags: [String] = [], materials: [SupportingMaterial] = []) {
        task?.cancel()
        debugSession.reset()
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
        self.forceRetranscribe = forceRetranscribe
        self.forceSpeakerSeparation = forceSpeakerSeparation
        let pendingJob = PendingMeetingJob(
            sourcePath: url.path, title: title ?? "", meetingContext: meetingContext,
            minutesTemplateID: minutesTemplateID,
            recognitionScenario: recognitionScenario,
            workspaceID: workspace?.id, customerName: customerName,
            projectName: projectName, tags: tags,
            materialPaths: materials.map { $0.sourceURL.path })
        pendingJobID = pendingJob.id
        try? PendingJobStore.save(pendingJob)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.execute(url: url, title: title, meetingContext: meetingContext,
                                       recordedAt: recordedAt,
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
            } catch {
                self.stage = .failed
                self.error = error.localizedDescription
            }
            PendingJobStore.clear(id: pendingJob.id)
            self.isRunning = false
        }
    }

    func run(imported package: ExternalTranscriptPackage,
             title: String? = nil, meetingContext: String = "",
             minutesTemplateID: String = MinutesTemplate.general.id,
             recognitionScenario: RecognitionScenario = .autoMultilingual,
             workspace: MeetingWorkspace? = nil,
             customerName: String = "", projectName: String = "",
             tags: [String] = [], materials: [SupportingMaterial] = []) {
        task?.cancel()
        debugSession.reset()
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
        usedCachedTranscript = true

        task = Task { [weak self] in
            guard let self else { return }
            do {
                self.stage = .probing
                self.progress = 1
                self.detail = "读取外部逐字稿（\(package.transcript.segments.count) 段）"
                var related = [package.transcriptURL]
                if let textURL = package.textURL { related.append(textURL) }
                if let audioURL = package.audioURL { related.append(audioURL) }
                let duration = max(package.transcript.duration,
                                   package.metadata.declaredDuration ?? 0)
                let bundle = MeetingAssets(
                    sourceURL: package.transcriptURL,
                    sourceKind: .importedTranscript,
                    relatedSourceURLs: related,
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
            } catch {
                self.stage = .failed
                self.error = error.localizedDescription
            }
            self.isRunning = false
        }
    }

    /// Re-runs diarization with the current speaker-count setting while still
    /// reusing the cached transcript. Useful when automatic clustering guessed
    /// poorly; transcription is not paid for again.
    func rerunSpeakerSeparation(speakerCount: Int = 0) {
        guard let bundle = assets, !isRunning else { return }
        run(url: bundle.sourceURL, forceSpeakerSeparation: true,
            recordedAt: bundle.recordedAt,
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
        await debugSession.before("读取文件", input: "文件：\(url.path)")
        let info = try await extractor.probe()
        guard info.hasAudio else { throw MediaExtractor.Failure.noAudioTrack }
        detail = "时长 \(TranscriptSegment.humanDuration(info.duration))" + (info.hasVideo ? "，含画面" : "")
        await debugSession.after("读取文件", output: "音频：\(info.hasAudio)，视频：\(info.hasVideo)，时长：\(info.duration)s")

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
            transcript = cached
            stage = .transcribing
            progress = 1
            detail = "复用已缓存的转录结果（\(cached.segments.count) 段）"
            usedCachedTranscript = true
            saveDebugTranscript(cached, label: "transcript-cached")
        }

        var diarization: Diarization?
        if wantsSpeakers, !forceRetranscribe, !forceSpeakerSeparation, let speakerKey,
           var cached = DiarizationCache.load(key: speakerKey) {
            // Names are derived state. Re-match on every cache read so profile
            // enrolment, rename and deletion take effect without re-diarizing.
            cached.names = VoiceProfileStore.match(embeddings: cached.embeddings)
            diarization = cached
        }

        // Audio is only needed for work that isn't already cached.
        let needsAudio = transcript == nil || (wantsSpeakers && diarization == nil)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-\(UUID().uuidString)")
        defer {
            if !settings.keepIntermediates { try? FileManager.default.removeItem(at: work) }
        }

        var audioURL: URL?
        if needsAudio {
            usedCachedTranscript = transcript != nil
            stage = .extractingAudio
            await debugSession.before("提取音轨", input: "需要音轨：转录或声纹缓存未命中")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let wav = work.appendingPathComponent("audio.wav")
            try await extractor.extractAudio(to: wav)
            try Task.checkCancellation()
            audioURL = wav
            await debugSession.after("提取音轨", output: "WAV：\(wav.path)，大小：\(Self.fileSize(wav))")
            if let artifact = debugSession.copyArtifact(from: wav, name: "audio.wav") {
                debugSession.writeLog("音频输出", artifact.path)
            }
        }

        if transcript == nil, let audioURL {
            usedCachedTranscript = false
            stage = .transcribing
            await debugSession.before("语音转录", input: "语言：\(recognitionScenario.whisperLanguage)，提示词长度：\(transcriptionPrompt.count)\n提示词全文：\n\(transcriptionPrompt)")
            progress = 0
            RecognitionMemoryStore.recordPromptUsage(
                workspaceID: workspace?.id, context: learningContext)
            let transcriber = Transcriber(audioURL: audioURL,
                                          language: recognitionScenario.whisperLanguage,
                                          glossary: transcriptionPrompt)
            let raw = try await transcriber.run { [weak self] seconds, _ in
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
            await debugSession.after("语音转录", output: "片段：\(fresh.segments.count)，文本预览：\(Self.preview(fresh.timecodedText))")
            saveDebugTranscript(fresh, label: "transcript")
        }

        // Silent or music-only input yields nothing to summarise; fail here
        // instead of spending a model call on an empty timeline.
        guard let transcript, !transcript.segments.isEmpty else { throw Failure.noSpeech }

        if wantsSpeakers, diarization == nil, let audioURL {
            stage = .separatingSpeakers
            await debugSession.before("分离说话人", input: "指定人数：\(speakerCount == 0 ? "自动" : String(speakerCount))")
            progress = 0
            detail = "分析声纹特征…"
            do {
                let result = try await Diarizer.run(
                    audioURL: audioURL,
                    speakerCount: speakerCount
                ) { [weak self] fraction in
                    Task { @MainActor in
                        self?.progress = fraction
                        self?.detail = String(format: "分离说话人 %.0f%%", fraction * 100)
                    }
                }
                if let speakerKey { DiarizationCache.save(result, key: speakerKey) }
                diarization = result
                await debugSession.after("分离说话人", output: "片段：\(result.segments.count)，声纹：\(result.embeddings.count)")
            } catch {
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
            await debugSession.before("提取画面", input: "采样密度：\(settings.frameDensity.displayName)，上限：\(settings.frameDensity.maxFrames)")
            progress = 0
            let density = settings.frameDensity
            captures = try await extractor.extractFrames(
                every: density.interval,
                maxFrames: density.maxFrames,
                distinctnessThreshold: density.distinctness
            ) { [weak self] value in
                Task { @MainActor in
                    self?.progress = value
                    self?.detail = "扫描画面变化…"
                }
            }
            try Task.checkCancellation()
            await debugSession.after("提取画面", output: "保留画面：\(captures.count)",
                                     image: captures.first?.image)
            for capture in captures {
                _ = debugSession.writeImageArtifact(capture.image,
                                                    name: String(format: "frame-%04d.png", capture.id))
            }

            stage = .readingScreen
            await debugSession.before("识别屏幕文字", input: "待 OCR 画面：\(captures.count)")
            progress = 0
            captures = await TextRecognizer.annotate(captures) { [weak self] value in
                Task { @MainActor in
                    self?.progress = value
                    self?.detail = "识别屏幕文字…"
                }
            }
            try Task.checkCancellation()
            detail = "保留 \(captures.count) 个不同画面"
            await debugSession.after("识别屏幕文字", output: "OCR 完成：\(captures.filter { !$0.recognizedText.isEmpty }.count) 个画面有文字")
            let ocr = captures.map {
                "【画面 \($0.id) · \($0.timecode)】\n\($0.textBlock)"
            }.joined(separator: "\n\n")
            _ = debugSession.writeTextArtifact(ocr, name: "screen-ocr.txt")
        }

        if var identified = diarization {
            identified.names.merge(speakerNames) { _, saved in saved }
            identified.roles = speakerRoles.filter { $0.value.isSpecified }
            diarization = identified
        }

        let bundle = MeetingAssets(sourceURL: url,
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
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
    }

    private func analyze(_ originalBundle: MeetingAssets) async throws {
        stage = .analyzing
        progress = 0
        detail = ""
        await debugSession.before("生成纪要", input: "逐字稿片段：\(originalBundle.transcript.segments.count)，画面：\(originalBundle.captures.count)，材料：\(originalBundle.materials.count)")

        var bundle = await addAdaptiveScreenEvidence(to: originalBundle)
        if var stats = bundle.adaptiveScreenReviewStats {
            stats.framesSentToModel = Analyzer.screenFramesSentToModel(
                assets: bundle, settings: Settings.shared).count
            bundle.adaptiveScreenReviewStats = stats
        }
        assets = bundle

        let analyzer = Analyzer(assets: bundle, settings: Settings.shared)
        let result = try await analyzer.run(debug: debugSession) { [weak self] message in
            Task { @MainActor in self?.detail = message }
        }
        await debugSession.after("生成纪要", output: "Markdown：\(result.markdown.count) 字，结构化结果：\(result.structured == nil ? "无" : "有")，回退：\(result.usedFallback)")
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
        var actionSuggestions: [ActionStatusSuggestion] = []
        if var structured = trackedStructured {
            let priorRecords = ((try? MeetingHistoryStore.loadAll()) ?? []).filter {
                $0.workspaceID == bundle.workspace?.id && $0.workspaceID != nil
                    && $0.createdAt < bundle.recordedAt
            }
            IssueTracking.prepare(&structured, priorRecords: priorRecords)
            actionSuggestions = ActionTracking.prepare(&structured, priorRecords: priorRecords)
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
        storedRecord.actionStatusSuggestions = actionSuggestions
        storedRecord.adaptiveScreenReviewStats = bundle.adaptiveScreenReviewStats
        storedRecord.generationUsage = generationUsage
        let reviewRisks = trackedStructured.map { IssuePreflight.risks(in: $0.issues) } ?? []
        let isHeadless = CommandLine.arguments.contains("--regenerate-record")
        if !isHeadless, trackedStructured?.issues.isEmpty == false,
           Settings.shared.alwaysReviewIssues || !reviewRisks.isEmpty {
            pendingReviewRecord = storedRecord
            pendingReviewMaterials = bundle.materials
            issueReviewReasons = reviewRisks
            stage = .reviewingIssues
            progress = 1
            detail = reviewRisks.isEmpty ? "请确认问题后生成最终纪要" : "检测到问题边界可能需要确认"
            return
        }
        persist(storedRecord, materials: bundle.materials)
        await debugSession.after("保存会议记录", output: "记录 ID：\(storedRecord.id.uuidString)，标题：\(storedRecord.title)")

        stage = .done
        progress = 1
        detail = "完成"
    }

    private static func preview(_ value: String) -> String {
        return value
    }

    private func saveDebugTranscript(_ transcript: Transcript, label: String) {
        _ = debugSession.writeTextArtifact(transcript.timecodedText, name: "\(label).txt")
        if let data = try? JSONEncoder().encode(transcript) {
            _ = debugSession.writeArtifact(data, name: "\(label).json")
        }
    }

    private static func fileSize(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
        persist(record, materials: pendingReviewMaterials)
        pendingReviewRecord = nil
        pendingReviewMaterials = []
        issueReviewReasons = []
        stage = .done
        progress = 1
        detail = "完成"
    }

    private func persist(_ record: MeetingRecord, materials: [SupportingMaterial]) {
        do {
            try MeetingHistoryStore.save(record, materialSources: materials)
            savedRecordID = record.id
            try ProjectLedgerStore.prepareProposals(for: record)
        } catch {
            historyWarning = "历史记录保存失败：\(error.localizedDescription)"
        }
    }

    /// A best-effort second look at the screen. Planning or image extraction
    /// must never turn a usable transcript into a failed meeting.
    private func addAdaptiveScreenEvidence(to bundle: MeetingAssets) async -> MeetingAssets {
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
            let extracted = try await MediaExtractor(url: bundle.sourceURL)
                .extractFrames(at: Array(probes.prefix(18)), startingID: nextID)
            let annotated = await TextRecognizer.annotate(extracted) { _ in }
            let useful = Self.newEvidenceFrames(annotated, comparedWith: bundle.captures)

            reviewStats.extractedFrames = extracted.count
            reviewStats.framesWithOCR = annotated.filter { !$0.recognizedText.isEmpty }.count
            reviewStats.acceptedFrames = useful.count

            var updated = bundle
            updated.captures.append(contentsOf: useful)
            updated.captures.sort { $0.time < $1.time }
            updated.adaptiveScreenReviewStats = reviewStats
            return completed(updated)
        } catch is CancellationError {
            return bundle
        } catch {
            detail = "补充画面失败，继续使用已提取内容…"
            var updated = bundle
            updated.adaptiveScreenReviewStats = reviewStats
            return completed(updated)
        }
    }

    /// Keeps only visually distinct probes that add OCR text or genuinely new
    /// pixels. This prevents three near-identical frames from consuming the
    /// final image budget.
    static func newEvidenceFrames(_ candidates: [ScreenCapture],
                                  comparedWith existing: [ScreenCapture]) -> [ScreenCapture] {
        var accepted: [ScreenCapture] = []
        let existingText = Set(existing.flatMap(\.recognizedText).map {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        })
        for candidate in candidates {
            let references = existing + accepted
            let visuallyNew = !references.contains {
                PerceptualHash.distance($0.fingerprint, candidate.fingerprint) < 8
            }
            let hasNewText = candidate.recognizedText.contains {
                !existingText.contains($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if visuallyNew || hasNewText { accepted.append(candidate) }
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
