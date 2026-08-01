import Foundation
import Observation

/// Drives one media file through the whole pipeline and publishes progress.
@Observable
@MainActor
final class PipelineRunner {

    enum Stage: String, CaseIterable {
        case idle, probing, extractingAudio, transcribing, extractingFrames, readingScreen, analyzing, done, failed

        var label: String {
            switch self {
            case .idle:             return "待机"
            case .probing:          return "读取文件"
            case .extractingAudio:  return "提取音轨"
            case .transcribing:     return "语音转录"
            case .extractingFrames: return "提取画面"
            case .readingScreen:    return "识别屏幕文字"
            case .analyzing:        return "生成纪要"
            case .done:             return "完成"
            case .failed:           return "失败"
            }
        }
    }

    private(set) var stage: Stage = .idle
    private(set) var progress: Double = 0
    private(set) var detail: String = ""
    private(set) var assets: MeetingAssets?
    private(set) var summary: String = ""
    private(set) var error: String?
    private(set) var isRunning = false

    /// True when transcription and screen extraction succeeded but the model
    /// call failed. The expensive work is still in `assets`, so the user can
    /// fix their key or switch provider and retry without redoing it.
    var canRetryAnalysis: Bool { assets != nil && summary.isEmpty }

    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        stage = .idle
        detail = "已取消"
    }

    func run(url: URL) {
        task?.cancel()
        error = nil
        summary = ""
        assets = nil
        isRunning = true

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

    private func execute(url: URL) async throws {
        let settings = Settings.shared
        let extractor = MediaExtractor(url: url)

        stage = .probing
        progress = 0
        let info = try await extractor.probe()
        guard info.hasAudio else { throw MediaExtractor.Failure.noAudioTrack }
        detail = "时长 \(TranscriptSegment.humanDuration(info.duration))" + (info.hasVideo ? "，含画面" : "")

        // --- audio -------------------------------------------------------
        stage = .extractingAudio
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer {
            if !settings.keepIntermediates { try? FileManager.default.removeItem(at: work) }
        }

        let audioURL = work.appendingPathComponent("audio.wav")
        try await extractor.extractAudio(to: audioURL)
        try Task.checkCancellation()

        // --- transcription ------------------------------------------------
        stage = .transcribing
        progress = 0
        let transcriber = Transcriber(audioURL: audioURL,
                                      language: settings.language,
                                      glossary: settings.glossary)
        let transcript = try await transcriber.run { [weak self] seconds, _ in
            Task { @MainActor in
                guard let self else { return }
                self.progress = min(seconds / max(info.duration, 1), 1)
                self.detail = "已转录 \(TranscriptSegment.timecode(seconds)) / \(TranscriptSegment.timecode(info.duration))"
            }
        }
        try Task.checkCancellation()

        // Silent or music-only input yields nothing to summarise; fail here
        // instead of spending a model call on an empty timeline.
        guard !transcript.segments.isEmpty else { throw Failure.noSpeech }

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
                                   hasVideo: info.hasVideo)
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
        summary = try await analyzer.run { [weak self] message in
            Task { @MainActor in self?.detail = message }
        }

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

        return summaryURL
    }
}
