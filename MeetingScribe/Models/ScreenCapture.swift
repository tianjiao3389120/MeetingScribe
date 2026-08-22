import Foundation
import CoreGraphics

/// A distinct thing that appeared on screen during the meeting.
///
/// This is the payload the audio alone cannot provide: slide titles, alert
/// counts, hostnames, dates. One capture stands for a run of near-identical
/// frames — `duration` is how long that content stayed up.
struct ScreenCapture: Identifiable, Sendable {
    let id: Int
    let time: TimeInterval
    var duration: TimeInterval
    let image: CGImage
    /// Text recognised on screen by Vision, in reading order.
    var recognizedText: [String] = []
    /// Present for transcript-driven probes, explaining what fact this frame
    /// was extracted to verify.
    var evidenceReason: String? = nil
    /// Perceptual hash used to fold duplicate frames together.
    let fingerprint: UInt64

    var timecode: String { TranscriptSegment.timecode(time) }

    /// Whether the frame is mostly text (a document or dashboard) as opposed to
    /// a diagram or photo. Text-heavy frames can go to the model as OCR text,
    /// which is far cheaper than sending the image.
    var isTextDominant: Bool { recognizedText.count >= 12 }

    var textBlock: String {
        recognizedText.joined(separator: "\n")
    }
}

/// Audit trail for transcript-driven screen review. Persisting every stage
/// makes it possible to distinguish "the planner ran" from evidence that the
/// minutes model could actually see and cite.
struct AdaptiveScreenReviewStats: Codable, Sendable, Equatable {
    var plannedNodes = 0
    var requestedProbes = 0
    var extractedFrames = 0
    var framesWithOCR = 0
    var acceptedFrames = 0
    var framesSentToModel = 0
    var citedScreenEvidence = 0

    var summary: String {
        "计划 \(plannedNodes) · 抽取 \(extractedFrames)/\(requestedProbes) · OCR有效 \(framesWithOCR) · 筛选保留 \(acceptedFrames) · 送入模型 \(framesSentToModel) · 最终引用 \(citedScreenEvidence)"
    }
}

/// Everything the pipeline extracted from one media file.
struct MeetingAssets: Sendable {
    enum SourceKind: String, Codable, Sendable {
        case recordedMedia
        case importedTranscript
    }

    var sourceURL: URL
    var sourceKind: SourceKind = .recordedMedia
    var relatedSourceURLs: [URL] = []
    var recordedAt: Date = Date()
    var customTitle: String?
    var meetingContext: String = ""
    var minutesTemplateID: String = MinutesTemplate.general.id
    /// Per-meeting choice; initialized from settings but never writes back to them.
    var recognitionScenario: RecognitionScenario = .autoMultilingual
    var duration: TimeInterval
    var transcript: Transcript
    var captures: [ScreenCapture]
    var hasVideo: Bool
    /// Prevents analysis retries from paying for the same adaptive review again.
    var adaptiveScreenReviewCompleted: Bool = false
    var adaptiveScreenReviewStats: AdaptiveScreenReviewStats? = nil
    /// Present only when speaker separation ran for this recording.
    var diarization: Diarization?
    var materials: [SupportingMaterial] = []
    var workspace: MeetingWorkspace?
    var tags: [String] = []

    var title: String {
        let value = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? sourceURL.deletingPathExtension().lastPathComponent : value
    }
}
