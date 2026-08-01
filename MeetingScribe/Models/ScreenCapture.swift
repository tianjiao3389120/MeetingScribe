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

/// Everything the pipeline extracted from one media file.
struct MeetingAssets: Sendable {
    var sourceURL: URL
    var duration: TimeInterval
    var transcript: Transcript
    var captures: [ScreenCapture]
    var hasVideo: Bool
    /// Present only when speaker separation ran for this recording.
    var diarization: Diarization?
    var materials: [SupportingMaterial] = []
    var workspace: MeetingWorkspace?
    var tags: [String] = []

    var title: String { sourceURL.deletingPathExtension().lastPathComponent }
}
