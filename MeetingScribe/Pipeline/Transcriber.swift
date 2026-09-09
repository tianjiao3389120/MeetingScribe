import Foundation

/// Runs whisper.cpp over the extracted audio.
///
/// Flags are the ones settled in TUNING.md against a 41-minute real meeting;
/// see that file before changing any of them.
struct Transcriber {

    let audioURL: URL
    let language: String
    let glossary: String

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
            "-t", String(ProcessInfo.processInfo.activeProcessorCount),
            "-mc", "-1",              // keep full context; -mc 0 cost 15% accuracy
            "-of", outputStem.path,
            "-osrt",
        ]

        // VAD removes the hallucination loops entirely and roughly halves runtime.
        if let vad = ToolLocator.vadModelPath() {
            arguments += ["--vad", "--vad-model", vad, "-vmsd", "12", "-vsd", "220"]
        }

        let prompt = Self.trimGlossary(glossary)
        if !prompt.isEmpty {
            arguments += ["--prompt", prompt, "--carry-initial-prompt"]
        }

        arguments.append(audioURL.path)

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
        try await Shell.check(whisper, arguments,
                              onStdoutLine: reportProgress,
                              onStderrLine: reportProgress)

        let srtURL = outputStem.appendingPathExtension("srt")
        let srt = try String(contentsOf: srtURL, encoding: .utf8)
        return Transcript.parse(srt: srt)
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
