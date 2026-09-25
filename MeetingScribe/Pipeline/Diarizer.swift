import Foundation

/// Speaker diarization via sherpa-onnx.
///
/// Runs out-of-process in a dedicated Python virtual environment. sherpa-onnx
/// has no Swift binding, and its wheel is only ~2MB with no PyTorch behind it,
/// so a venv is cheaper than embedding an ONNX runtime — and keeps the app's
/// own dependencies unchanged when it isn't used.
struct Diarizer {

    /// Automatic clustering used to run at 0.80. Real meeting samples showed
    /// split recordings of the same person around 0.73-0.77 while distinct
    /// enrolled voices stayed below 0.56. Keep a safety margin above sherpa's
    /// 0.50 default without turning microphone/noise changes into new people.
    static let automaticClusteringThreshold: Float = 0.72

    /// Everything this feature installs lives here, so removing the directory
    /// fully uninstalls it.
    static let supportDirectory: URL = {
        let base = AppEnvironment.supportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var venvDirectory: URL { AppEnvironment.sharedEngineDirectory.appendingPathComponent("diarize-venv") }
    static var modelDirectory: URL { AppEnvironment.sharedEngineDirectory.appendingPathComponent("diarize-models") }
    static var pythonPath: URL { venvDirectory.appendingPathComponent("bin/python") }
    static var scriptPath: URL { AppEnvironment.sharedEngineDirectory.appendingPathComponent("diarize.py") }

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
    static let segmentationArchiveSHA256 =
        "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488"
    static let segmentationModelSHA256 =
        "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d"
    static let embeddingModelSHA256 =
        "f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11"

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
        FileIntegrity.matchesSHA256(
            segmentationModelSHA256,
            at: modelDirectory.appendingPathComponent(segmentationModel))
            && FileIntegrity.matchesSHA256(
                embeddingModelSHA256,
                at: modelDirectory.appendingPathComponent(embeddingModel))
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
        try FileManager.default.createDirectory(
            at: AppEnvironment.sharedEngineDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: venvDirectory)
        try await Shell.check(python, ["-m", "venv", venvDirectory.path], timeout: 300)

        progress("安装 sherpa-onnx（约 2MB）…")
        try await Shell.check(venvDirectory.appendingPathComponent("bin/pip").path,
                              ["install", "--quiet", "--only-binary=:all:",
                               "sherpa-onnx==1.13.4", "numpy==2.5.1"],
                              timeout: 900)

        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        progress("运行环境就绪")
    }

    static func downloadModels(progress: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let segmentation = modelDirectory.appendingPathComponent(segmentationModel)
        if !FileIntegrity.matchesSHA256(segmentationModelSHA256, at: segmentation) {
            try? FileManager.default.removeItem(
                at: modelDirectory.appendingPathComponent("sherpa-onnx-pyannote-segmentation-3-0"))
            progress("下载分段模型…")
            let archive = modelDirectory.appendingPathComponent("segmentation.tar.bz2")
            try await download(segmentationArchiveURL, to: archive,
                               expectedSHA256: segmentationArchiveSHA256) { _ in }
            try await Shell.check("/usr/bin/tar",
                                  ["xjf", archive.path, "-C", modelDirectory.path],
                                  timeout: 120)
            try? FileManager.default.removeItem(at: archive)
            guard FileIntegrity.matchesSHA256(segmentationModelSHA256, at: segmentation) else {
                throw Failure.integrityCheckFailed
            }
        }

        let embedding = modelDirectory.appendingPathComponent(embeddingModel)
        if !FileIntegrity.matchesSHA256(embeddingModelSHA256, at: embedding) {
            try await download(embeddingModelURL,
                               to: embedding,
                               expectedSHA256: embeddingModelSHA256) { fraction in
                progress(String(format: "下载声纹模型 %.0f%%", fraction * 100))
            }
        }
        progress("模型就绪")
    }

    private static func download(_ urlString: String,
                                 to destination: URL,
                                 expectedSHA256: String,
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
        guard FileIntegrity.matchesSHA256(expectedSHA256, at: partial) else {
            try? FileManager.default.removeItem(at: partial)
            throw Failure.integrityCheckFailed
        }
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

        return Diarization(segments: payload.segments,
                           embeddings: payload.embeddings,
                           embeddingQualities: payload.embeddingQualities,
                           referenceSegments: payload.referenceSegments)
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
        let embeddingQualities: [String: VoiceEmbeddingQuality]
        let referenceSegments: [String: VoiceReferenceSegment]

        private enum CodingKeys: String, CodingKey {
            case segments, embeddings, embeddingQualities, referenceSegments
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            segments = try values.decode([SpeakerSegment].self, forKey: .segments)
            embeddings = try values.decode([String: [Float]].self, forKey: .embeddings)
            embeddingQualities = try values.decodeIfPresent(
                [String: VoiceEmbeddingQuality].self, forKey: .embeddingQualities) ?? [:]
            referenceSegments = try values.decodeIfPresent(
                [String: VoiceReferenceSegment].self, forKey: .referenceSegments) ?? [:]
        }
    }

    enum Failure: LocalizedError {
        case noPython, notReady, badURL, downloadFailed, integrityCheckFailed, noSpeakers

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
            case .integrityCheckFailed:
                return "模型完整性校验失败，已拒绝安装。"
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
            threshold=0.0 if want > 0 else \#(automaticClusteringThreshold),
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

    # Build a quality-gated voiceprint per speaker. Boundary speech, overlap,
    # clipping and very weak audio are common sources of poisoned profiles.
    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
        sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=spk_model, num_threads=6))

    by_speaker = {}
    for s in segments:
        by_speaker.setdefault(s["speaker"], []).append(s)

    def overlap_with_other(item):
        overlap = 0.0
        for other in segments:
            if other["speaker"] == item["speaker"]:
                continue
            overlap = max(overlap, min(item["end"], other["end"]) - max(item["start"], other["start"]))
        return max(0.0, overlap)

    def candidate(item, allow_overlap=False):
        trim = 0.25
        start, end = item["start"] + trim, item["end"] - trim
        if end - start < 1.5:
            return None
        if end - start > 12.0:
            center = (start + end) / 2.0
            start, end = center - 6.0, center + 6.0
        if not allow_overlap and overlap_with_other(item) > 0.12:
            return None
        a, b = int(start * 16000), int(end * 16000)
        chunk = audio[a:b]
        if len(chunk) < 24000:
            return None
        absolute = np.abs(chunk)
        rms = float(np.sqrt(np.mean(chunk * chunk)))
        peak = float(np.max(absolute))
        clipping = float(np.mean(absolute >= 0.995))
        if rms < 0.003 or peak < 0.01 or clipping > 0.03:
            return None
        duration_score = min(1.0, (end - start) / 6.0)
        level_score = min(1.0, max(0.0, (rms - 0.003) / 0.035))
        clipping_score = max(0.0, 1.0 - clipping / 0.015)
        quality = 0.35 * duration_score + 0.40 * level_score + 0.25 * clipping_score
        if allow_overlap:
            quality *= 0.65
        return {"chunk": chunk, "duration": end - start, "quality": quality,
                "start": start, "end": end, "isClean": not allow_overlap}

    embeddings, embedding_qualities, reference_segments = {}, {}, {}
    for speaker, items in by_speaker.items():
        clean_candidates = [candidate(item) for item in items]
        clean_candidates = [item for item in clean_candidates if item is not None]
        candidates = clean_candidates
        if not candidates:
            candidates = [candidate(item, allow_overlap=True) for item in items]
            candidates = [item for item in candidates if item is not None]
        candidates.sort(key=lambda x: x["quality"], reverse=True)
        if candidates:
            best = candidates[0]
            reference_segments[str(speaker)] = {
                "start": best["start"], "end": best["end"],
                "quality": best["quality"], "isClean": best["isClean"],
            }
        vectors, weights, qualities, durations, used = [], [], [], [], 0.0
        clean_used = 0
        for item in candidates:
            if used >= 30.0 or len(vectors) >= 8:
                break
            duration = min(item["duration"], 30.0 - used)
            if duration < 1.5:
                break
            chunk = item["chunk"][:int(duration * 16000)]
            stream = extractor.create_stream()
            stream.accept_waveform(sample_rate=16000, waveform=chunk)
            stream.input_finished()
            vector = np.array(extractor.compute(stream), dtype=np.float32)
            vector_norm = np.linalg.norm(vector)
            if vector_norm <= 0:
                continue
            vectors.append(vector / vector_norm)
            weights.append(max(0.1, item["quality"]) * duration)
            qualities.append(item["quality"])
            durations.append(duration)
            if item["isClean"]:
                clean_used += 1
            used += duration
        if vectors:
            mean = np.average(np.stack(vectors), axis=0, weights=np.array(weights))
            norm = np.linalg.norm(mean)
            average_quality = float(np.average(
                np.array(qualities), weights=np.array(durations)))
            embedding_qualities[str(speaker)] = {
                "score": average_quality,
                "usableDuration": used,
                "segmentCount": len(vectors),
                "cleanSegmentCount": clean_used,
            }
            if norm > 0 and average_quality >= 0.42:
                embeddings[str(speaker)] = (mean / norm).tolist()

    json.dump({"segments": segments, "embeddings": embeddings,
               "embeddingQualities": embedding_qualities,
               "referenceSegments": reference_segments}, open(out, "w"))
    """#
}
