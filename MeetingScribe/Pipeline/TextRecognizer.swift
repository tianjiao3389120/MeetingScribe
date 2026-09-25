import Foundation
import Vision
import CoreGraphics

/// Reads on-screen text with the system Vision framework.
///
/// Doing this locally matters twice over: it is free and offline, and it lets
/// the pipeline send most frames to the model as text instead of images —
/// a dashboard screenshot costs ~1.5k image tokens but only ~200 as text.
struct TextRecognizer {

    /// Recognised text for each capture, in reading order.
    static func annotate(
        _ captures: [ScreenCapture],
        progress: @Sendable (Double) -> Void
    ) async -> [ScreenCapture] {

        var annotated = captures
        for index in captures.indices {
            if Task.isCancelled { break }
            progress(Double(index) / Double(max(captures.count, 1)))
            annotated[index].recognizedText = recognize(captures[index].image)
        }
        progress(1)
        return annotated
    }

    static func recognize(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Chinese first: the Simplified Chinese model also covers Latin text,
        // so mixed UI (中文界面 + English hostnames) comes out in one pass.
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }

        // Vision returns observations in no particular order; sort into reading
        // order so a table of alerts stays row-aligned in the text output.
        let lines = observations.compactMap { observation -> (CGRect, String)? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence > 0.3 else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 1 else { return nil }
            return (observation.boundingBox, text)
        }

        return lines
            .sorted { a, b in
                // Vision's origin is bottom-left, so higher maxY comes first.
                if abs(a.0.midY - b.0.midY) > 0.015 { return a.0.midY > b.0.midY }
                return a.0.minX < b.0.minX
            }
            .map(\.1)
    }
}
