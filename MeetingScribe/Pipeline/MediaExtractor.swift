@preconcurrency import AVFoundation
import CoreImage
import Foundation

/// Pulls audio and screen frames out of a media file using AVFoundation.
///
/// Replaces the ffmpeg calls the prototype shelled out to: no external binary,
/// no GPL redistribution question, and hardware-accelerated decode for free.
struct MediaExtractor {

    enum Failure: LocalizedError {
        case noAudioTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:        return "文件里没有音轨"
            case .exportFailed(let m): return "音频导出失败：\(m)"
            }
        }
    }

    let url: URL

    func probe() async throws -> (duration: TimeInterval, hasVideo: Bool, hasAudio: Bool) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        return (duration, !video.isEmpty, !audio.isEmpty)
    }

    /// Writes 16 kHz mono PCM — the only format whisper.cpp accepts.
    func extractAudio(to destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw Failure.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        // AVFoundation marks these reference types non-Sendable even though
        // this method confines all streaming access to one serial queue.
        let stream = AudioExportStream(reader: reader, output: output,
                                       writer: writer, input: input)

        guard reader.startReading(), writer.startWriting() else {
            throw Failure.exportFailed(reader.error?.localizedDescription
                                       ?? writer.error?.localizedDescription ?? "未知错误")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "audio-export")
        let cancelled = Cancellation()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) {
                    while stream.input.isReadyForMoreMediaData {
                        // Long files spend real time here; honour cancellation
                        // rather than running the export to completion.
                        if cancelled.isSet {
                            stream.reader.cancelReading()
                            stream.input.markAsFinished()
                            stream.writer.cancelWriting()
                            continuation.resume()
                            return
                        }
                        guard let buffer = stream.output.copyNextSampleBuffer() else {
                            stream.input.markAsFinished()
                            stream.writer.finishWriting { continuation.resume() }
                            return
                        }
                        stream.input.append(buffer)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }

        try Task.checkCancellation()

        if writer.status == .failed {
            throw Failure.exportFailed(writer.error?.localizedDescription ?? "未知错误")
        }
    }

    /// Exports a short excerpt, used to play back a speaker's voice while the
    /// user puts a name to them.
    func exportClip(from start: TimeInterval, duration: TimeInterval, to destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetAppleM4A)
        else { throw Failure.exportFailed("无法创建导出会话") }

        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600))

        await session.export()
        if session.status != .completed {
            throw Failure.exportFailed(session.error?.localizedDescription ?? "导出未完成")
        }
    }

    /// Samples the video every `interval` seconds and keeps frames that differ
    /// from the previous kept frame.
    ///
    /// Sampling at a fixed interval and filtering by perceptual hash beats
    /// ffmpeg's scene-change detection here: on a screen recording, a moving
    /// cursor or a webcam thumbnail trips `scene` constantly. A real slide
    /// change moves many hash bits at once; a cursor moves none.
    func extractFrames(
        every interval: TimeInterval,
        maxFrames: Int,
        distinctnessThreshold: Int,
        progress: @Sendable (Double) -> Void
    ) async throws -> [ScreenCapture] {

        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return [] }
        let duration = try await asset.load(.duration).seconds

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
        // Downscale during decode. Text stays legible for OCR well below native
        // resolution, and it keeps memory flat on long recordings.
        generator.maximumSize = CGSize(width: 1600, height: 1600)

        var captures: [ScreenCapture] = []
        var lastFingerprint: UInt64?
        var stamps: [TimeInterval] = []
        var t: TimeInterval = 1
        while t < duration { stamps.append(t); t += interval }

        for (index, stamp) in stamps.enumerated() {
            if Task.isCancelled { break }
            progress(Double(index) / Double(max(stamps.count, 1)))

            let time = CMTime(seconds: stamp, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }

            let fingerprint = PerceptualHash.compute(image)
            if let last = lastFingerprint {
                let distance = PerceptualHash.distance(last, fingerprint)
                if distance < distinctnessThreshold {
                    // Same content still on screen — extend the previous entry.
                    if !captures.isEmpty {
                        captures[captures.count - 1].duration = stamp - captures[captures.count - 1].time
                    }
                    continue
                }
            }

            captures.append(ScreenCapture(id: captures.count, time: stamp,
                                          duration: interval, image: image,
                                          fingerprint: fingerprint))
            lastFingerprint = fingerprint
        }

        progress(1)
        return prune(captures, to: maxFrames)
    }

    /// If we still have too many, keep the ones that stayed on screen longest —
    /// a slide someone talked over for two minutes matters more than a frame
    /// caught mid-scroll.
    private func prune(_ captures: [ScreenCapture], to limit: Int) -> [ScreenCapture] {
        guard captures.count > limit else { return captures }
        let kept = captures.sorted { $0.duration > $1.duration }.prefix(limit)
        return kept.sorted { $0.time < $1.time }
    }
}

/// Accessed only by MediaExtractor's serial export queue.
private final class AudioExportStream: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let writer: AVAssetWriter
    let input: AVAssetWriterInput

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput,
         writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
    }
}

/// One-way flag shared between the cancellation handler and the export queue.
private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// 64-bit dHash: downscale to 9×8 greyscale, then record whether each pixel is
/// brighter than the one to its right.
enum PerceptualHash {

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func compute(_ image: CGImage) -> UInt64 {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<height {
            for column in 0..<(width - 1) {
                let left = pixels[row * width + column]
                let right = pixels[row * width + column + 1]
                if left > right { hash |= (1 << UInt64(bit)) }
                bit += 1
            }
        }
        return hash
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
