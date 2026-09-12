import Foundation

/// Runs whisper.cpp over the extracted audio.
///
/// Flags are the ones settled in TUNING.md against a 41-minute real meeting;
/// see that file before changing any of them.
struct Transcriber {

    let audioURL: URL
    let language: String
    let glossary: String
    let performance: TranscriptionPerformance

    func run(progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        let whisper = try ToolLocator.require(.whisper)
        guard let model = ToolLocator.modelPath() else { throw ToolError.modelMissing }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let outputStem = workDirectory.appendingPathComponent("out")

        var arguments = [
            "-m", model,
            "-l", language,
            "-t", String(max(2, Int((Double(ProcessInfo.processInfo.activeProcessorCount) * performance.threadFraction).rounded()))),
            "-mc", "-1",              // keep full context; -mc 0 cost 15% accuracy
            "-of", outputStem.path,
            "-osrt",
        ]
        if performance.disablesGPU { arguments.append("-ng") }

        // VAD removes the hallucination loops entirely and roughly halves runtime.
        if let vad = ToolLocator.vadModelPath() {
            arguments += ["--vad", "--vad-model", vad, "-vmsd", "12", "-vsd", "220"]
        }

        let prompt = Self.trimGlossary(glossary)
        if !prompt.isEmpty {
            arguments += ["--prompt", prompt, "--carry-initial-prompt"]
        }

        arguments.append(audioURL.path)

        let debug = PipelineDebugRegistry.active
        let promptHandle = debug?.promptStart(
            id: "transcription.v2", node: "语音转录", engine: "Whisper CLI",
            model: URL(fileURLWithPath: model).lastPathComponent,
            purpose: "提供专有名词和项目术语，改善语音识别准确度",
            source: "Transcriber.swift",
            system: "Whisper initial prompt（最多保留约 170 个中文字符）",
            user: prompt)

        let reportProgress: @Sendable (String) -> Void = { line in
            // whisper logs "[00:12:34.000 --> ...]" per segment; use the left
            // timestamp as a progress signal.
            guard let range = line.range(of: #"\[(\d+):(\d+):(\d+)"#, options: .regularExpression)
            else { return }
            let parts = line[range].dropFirst().components(separatedBy: ":")
            guard parts.count == 3, let h = Double(parts[0]),
                  let m = Double(parts[1]), let s = Double(parts[2]) else { return }
            progress(h * 3600 + m * 60 + s, line)
        }
        do {
            try await Shell.check(whisper, arguments,
                                  qualityOfService: .utility,
                                  onStdoutLine: reportProgress,
                                  onStderrLine: reportProgress)
            let srtURL = outputStem.appendingPathExtension("srt")
            let srt = try String(contentsOf: srtURL, encoding: .utf8)
            let transcript = Transcript.parse(srt: srt)
            if let promptHandle { debug?.promptEnd(promptHandle, output: "转录结果：\(transcript.segments.count) 段\nSRT 字符数：\(srt.count)") }
            return transcript
        } catch {
            if let promptHandle { debug?.promptEnd(promptHandle, output: "失败：\(error.localizedDescription)", status: "failed") }
            throw error
        }
    }

    /// whisper's initial prompt caps around 224 tokens. Chinese runs roughly
    /// 1.3 tokens per character, so keep it under ~170 characters.
    static func trimGlossary(_ raw: String) -> String {
        let body = raw
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(body.prefix(170))
    }
}
