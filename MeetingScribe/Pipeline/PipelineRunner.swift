import Foundation
import Observation

/// Drives one media file through the whole pipeline and publishes progress.
@Observable
@MainActor
final class PipelineRunner {

    enum Stage: String, CaseIterable {
        case idle, probing, extractingAudio, transcribing, separatingSpeakers,
             extractingFrames, readingScreen, analyzing, done, failed

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
    private(set) var error: String?
    private(set) var isRunning = false

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

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        stage = .idle
        detail = "已取消"
    }

    func run(url: URL, forceRetranscribe: Bool = false,
             forceSpeakerSeparation: Bool = false) {
        task?.cancel()
        error = nil
        summary = ""
        structuredSummary = nil
        usedSummaryFallback = false
        assets = nil
        isRunning = true
        speakerWarning = nil
        self.forceRetranscribe = forceRetranscribe
        self.forceSpeakerSeparation = forceSpeakerSeparation

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.execute(url: url)
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
    func rerunSpeakerSeparation() {
        guard let sourceURL = assets?.sourceURL, !isRunning else { return }
        run(url: sourceURL, forceSpeakerSeparation: true)
    }

    /// Re-runs only the model call, reusing the existing transcript and captures.
    func retryAnalysis() {
        guard let bundle = assets, !isRunning else { return }
        task?.cancel()
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

    /// Applies names enrolled from this meeting before regenerating the
    /// summary, so the current result benefits immediately rather than only
    /// future recordings.
    func applySpeakerNamesAndRegenerate(_ names: [Int: String]) {
        guard var bundle = assets, var diarization = bundle.diarization else { return }
        diarization.names.merge(names) { _, new in new }
        bundle.diarization = diarization
        assets = bundle
        retryAnalysis()
    }

    private func execute(url: URL) async throws {
        let settings = Settings.shared
        let extractor = MediaExtractor(url: url)

        stage = .probing
        progress = 0
        let info = try await extractor.probe()
        guard info.hasAudio else { throw MediaExtractor.Failure.noAudioTrack }
        detail = "时长 \(TranscriptSegment.humanDuration(info.duration))" + (info.hasVideo ? "，含画面" : "")

        // --- transcription and diarization ---------------------------------
        let transcriptKey = TranscriptCache.key(for: url,
                                                language: settings.language,
                                                glossary: settings.glossary)
        let wantsSpeakers = settings.separateSpeakers && Diarizer.readiness().isReady
        let speakerKey = wantsSpeakers
            ? TranscriptCache.key(for: url,
                                  language: "speakers-\(settings.expectedSpeakerCount)",
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
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let wav = work.appendingPathComponent("audio.wav")
            try await extractor.extractAudio(to: wav)
            try Task.checkCancellation()
            audioURL = wav
        }

        if transcript == nil, let audioURL {
            usedCachedTranscript = false
            stage = .transcribing
            progress = 0
            let transcriber = Transcriber(audioURL: audioURL,
                                          language: settings.language,
                                          glossary: settings.glossary)
            let fresh = try await transcriber.run { [weak self] seconds, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.progress = min(seconds / max(info.duration, 1), 1)
                    self.detail = "已转录 \(TranscriptSegment.timecode(seconds)) / \(TranscriptSegment.timecode(info.duration))"
                }
            }
            try Task.checkCancellation()
            if let transcriptKey { TranscriptCache.save(fresh, key: transcriptKey) }
            transcript = fresh
        }

        // Silent or music-only input yields nothing to summarise; fail here
        // instead of spending a model call on an empty timeline.
        guard let transcript, !transcript.segments.isEmpty else { throw Failure.noSpeech }

        if wantsSpeakers, diarization == nil, let audioURL {
            stage = .separatingSpeakers
            progress = 0
            detail = "分析声纹特征…"
            do {
                let result = try await Diarizer.run(
                    audioURL: audioURL,
                    speakerCount: settings.expectedSpeakerCount
                ) { [weak self] fraction in
                    Task { @MainActor in
                        self?.progress = fraction
                        self?.detail = String(format: "分离说话人 %.0f%%", fraction * 100)
                    }
                }
                if let speakerKey { DiarizationCache.save(result, key: speakerKey) }
                diarization = result
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

            stage = .readingScreen
            progress = 0
            captures = await TextRecognizer.annotate(captures) { [weak self] value in
                Task { @MainActor in
                    self?.progress = value
                    self?.detail = "识别屏幕文字…"
                }
            }
            try Task.checkCancellation()
            detail = "保留 \(captures.count) 个不同画面"
        }

        let bundle = MeetingAssets(sourceURL: url,
                                   duration: info.duration,
                                   transcript: transcript,
                                   captures: captures,
                                   hasVideo: info.hasVideo,
                                   diarization: diarization)
        // Publish before analysing: if the model call fails, the transcript and
        // captures survive and `retryAnalysis()` can reuse them.
        assets = bundle

        try await analyze(bundle)
    }

    private func analyze(_ bundle: MeetingAssets) async throws {
        stage = .analyzing
        progress = 0
        detail = ""

        let analyzer = Analyzer(assets: bundle, settings: Settings.shared)
        let result = try await analyzer.run { [weak self] message in
            Task { @MainActor in self?.detail = message }
        }
        summary = result.markdown
        structuredSummary = result.structured
        usedSummaryFallback = result.usedFallback

        stage = .done
        progress = 1
        detail = "完成"
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
