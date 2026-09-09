import Foundation

/// Speaker diarization via sherpa-onnx.
///
/// Runs out-of-process in a dedicated Python virtual environment. sherpa-onnx
/// has no Swift binding, and its wheel is only ~2MB with no PyTorch behind it,
/// so a venv is cheaper than embedding an ONNX runtime — and keeps the app's
/// own dependencies unchanged when it isn't used.
struct Diarizer {

    /// Everything this feature installs lives here, so removing the directory
    /// fully uninstalls it.
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var venvDirectory: URL { supportDirectory.appendingPathComponent("diarize-venv") }
    static var modelDirectory: URL { supportDirectory.appendingPathComponent("diarize-models") }
    static var pythonPath: URL { venvDirectory.appendingPathComponent("bin/python") }
    static var scriptPath: URL { supportDirectory.appendingPathComponent("diarize.py") }

    /// Benchmarked against a 41-minute meeting: this pairing runs 3.7× faster
    /// than the larger `eres2netv2` embedding model with identical speaker
    /// purity (94.2% vs 94.1% on the main presenter's stretch). The bottleneck
    /// is the embedding model, not segmentation — quantising segmentation alone
    /// changed nothing.
    static let segmentationModel = "sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx"
    static let embeddingModel = "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"

    static let segmentationArchiveURL =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
    static let embeddingModelURL =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/\(embeddingModel)"

    // MARK: - Availability

    enum Readiness: Equatable {
        case ready
        case needsRuntime      // venv missing or sherpa-onnx not installed
        case needsModels
        case noPython

        var isReady: Bool { self == .ready }
    }

    static func readiness() -> Readiness {
        guard systemPython() != nil else { return .noPython }
        guard FileManager.default.isExecutableFile(atPath: pythonPath.path) else { return .needsRuntime }
        guard modelsPresent else { return .needsModels }
        return .ready
    }

    static var modelsPresent: Bool {
        let files = FileManager.default
        return files.fileExists(atPath: modelDirectory.appendingPathComponent(segmentationModel).path)
            && files.fileExists(atPath: modelDirectory.appendingPathComponent(embeddingModel).path)
    }

    static func systemPython() -> String? {
        for candidate in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    // MARK: - Setup

    static func installRuntime(progress: @escaping @Sendable (String) -> Void) async throws {
        guard let python = systemPython() else { throw Failure.noPython }

        progress("创建 Python 环境…")
        try? FileManager.default.removeItem(at: venvDirectory)
        try await Shell.check(python, ["-m", "venv", venvDirectory.path], timeout: 300)

        progress("安装 sherpa-onnx（约 2MB）…")
        try await Shell.check(venvDirectory.appendingPathComponent("bin/pip").path,
                              ["install", "--quiet", "sherpa-onnx", "numpy"],
                              timeout: 900)

        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        progress("运行环境就绪")
    }

    static func downloadModels(progress: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(
            atPath: modelDirectory.appendingPathComponent(segmentationModel).path) {
            progress("下载分段模型…")
            let archive = modelDirectory.appendingPathComponent("segmentation.tar.bz2")
            try await download(segmentationArchiveURL, to: archive) { _ in }
            try await Shell.check("/usr/bin/tar",
                                  ["xjf", archive.path, "-C", modelDirectory.path],
                                  timeout: 120)
            try? FileManager.default.removeItem(at: archive)
        }

        if !FileManager.default.fileExists(
            atPath: modelDirectory.appendingPathComponent(embeddingModel).path) {
            try await download(embeddingModelURL,
                               to: modelDirectory.appendingPathComponent(embeddingModel)) { fraction in
                progress(String(format: "下载声纹模型 %.0f%%", fraction * 100))
            }
        }
        progress("模型就绪")
    }

    private static func download(_ urlString: String,
                                 to destination: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = URL(string: urlString) else { throw Failure.badURL }
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.downloadFailed }
        let expected = response.expectedContentLength

        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 { progress(Double(written) / Double(expected)) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); written += Int64(buffer.count) }
        try handle.close()

        if expected > 0, written < expected { throw Failure.downloadFailed }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    // MARK: - Run

    /// `speakerCount` of 0 lets clustering decide; a known headcount is more
    /// reliable on compressed conference audio, where automatic clustering
    /// tends to over-split.
    static func run(audioURL: URL,
                    speakerCount: Int,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> Diarization {
        guard readiness().isReady else { throw Failure.notReady }
        // The Python helper is bundled as source in the executable. Always
        // refresh it before a run: keeping an old on-disk copy across app
        // upgrades silently preserves old output schemas (notably, builds
        // before voice embeddings were added).
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("diarize-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        try await Shell.check(
            pythonPath.path,
            [scriptPath.path,
             audioURL.path,
             modelDirectory.appendingPathComponent(segmentationModel).path,
             modelDirectory.appendingPathComponent(embeddingModel).path,
             output.path,
             String(speakerCount)],
            timeout: 3600,
            onStderrLine: { line in
            // The script reports "PROGRESS <done> <total>" on stderr.
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "PROGRESS",
                  let done = Double(parts[1]), let total = Double(parts[2]), total > 0
            else { return }
            progress(done / total)
        })

        let data = try Data(contentsOf: output)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.segments.isEmpty else { throw Failure.noSpeakers }

        var diarization = Diarization(segments: payload.segments,
                                      embeddings: payload.embeddings)
        diarization.names = VoiceProfileStore.match(embeddings: payload.embeddings)
        return diarization
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: venvDirectory)
        try? FileManager.default.removeItem(at: modelDirectory)
        try? FileManager.default.removeItem(at: scriptPath)
    }

    static var installedSize: Int64 {
        [venvDirectory, modelDirectory].reduce(Int64(0)) { total, dir in
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            else { return total }
            return total + e.reduce(Int64(0)) { sum, item in
                guard let url = item as? URL,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                else { return sum }
                return sum + Int64(size)
            }
        }
    }

    private struct Payload: Decodable {
        let segments: [SpeakerSegment]
        let embeddings: [String: [Float]]
    }

    enum Failure: LocalizedError {
        case noPython, notReady, badURL, downloadFailed, noSpeakers

        var errorDescription: String? {
            switch self {
            case .noPython:
                return "找不到 python3。可通过 brew install python 安装后重试。"
            case .notReady:
                return "说话人分离尚未安装完成，请到设置里完成安装。"
            case .badURL:
                return "模型下载地址无效。"
            case .downloadFailed:
                return "模型下载失败或不完整，请重试。"
            case .noSpeakers:
                return "没有分离出任何说话人，音频可能过短或没有语音。"
            }
        }
    }

    /// Written to disk on setup and invoked by the venv's interpreter.
    private static let script = #"""
    import sys, json, wave
    import numpy as np
    import sherpa_onnx

    wav, seg_model, spk_model, out = sys.argv[1:5]
    want = int(sys.argv[5]) if len(sys.argv) > 5 else 0

    with wave.open(wav) as f:
        audio = np.frombuffer(f.readframes(f.getnframes()), dtype=np.int16).astype(np.float32) / 32768

    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=seg_model),
            num_threads=6,
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=spk_model, num_threads=6),
        clustering=sherpa_onnx.FastClusteringConfig(
            num_clusters=want if want > 0 else -1,
            threshold=0.0 if want > 0 else 0.8,
        ),
        min_duration_on=0.5,
        min_duration_off=0.6,
    )
    if not config.validate():
        print("invalid diarization config", file=sys.stderr)
        sys.exit(1)

    def report(done, total):
        print(f"PROGRESS {done} {total}", file=sys.stderr, flush=True)
        return 0

    result = sherpa_onnx.OfflineSpeakerDiarization(config).process(
        audio, callback=report).sort_by_start_time()

    segments = [{"start": r.start, "end": r.end, "speaker": r.speaker} for r in result]

    # A representative voiceprint per speaker, so callers can match this
    # meeting's clusters against previously enrolled people. Built from the
    # longest turns — short interjections carry too little signal.
    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
        sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=spk_model, num_threads=6))

    by_speaker = {}
    for s in segments:
        by_speaker.setdefault(s["speaker"], []).append(s)

    embeddings = {}
    for speaker, items in by_speaker.items():
        items.sort(key=lambda x: x["end"] - x["start"], reverse=True)
        vectors, used = [], 0.0
        for item in items:
            if used >= 30.0 or len(vectors) >= 8:
                break
            a, b = int(item["start"] * 16000), int(item["end"] * 16000)
            chunk = audio[a:b]
            if len(chunk) < 16000:        # under a second is not worth embedding
                continue
            stream = extractor.create_stream()
            stream.accept_waveform(sample_rate=16000, waveform=chunk)
            stream.input_finished()
            vectors.append(np.array(extractor.compute(stream), dtype=np.float32))
            used += item["end"] - item["start"]
        if vectors:
            mean = np.mean(vectors, axis=0)
            norm = np.linalg.norm(mean)
            if norm > 0:
                embeddings[str(speaker)] = (mean / norm).tolist()

    json.dump({"segments": segments, "embeddings": embeddings}, open(out, "w"))
    """#
}
