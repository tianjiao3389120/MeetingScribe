import Foundation

/// Finds whisper-cli, local model CLIs, and the whisper models on disk.
///
/// A missing tool is a normal state, not a crash: the UI reports what is
/// missing and how to install it.
enum ToolLocator {

    /// Keep meeting analysis isolated from repository instructions, personal
    /// skills and saved sessions while retaining the CLI's existing login.
    static let codexExecArguments = [
        "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
        "--sandbox", "read-only", "--skip-git-repo-check", "--color", "never", "-",
    ]

    enum Tool: String, CaseIterable, Identifiable {
        case whisper, claude, codex

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .whisper: return "whisper-cli"
            case .claude:  return "claude"
            case .codex:   return "codex"
            }
        }

        var candidates: [String] {
            switch self {
            case .whisper:
                return ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli",
                        "/opt/homebrew/bin/whisper-cpp", "/usr/local/bin/whisper-cpp"]
            case .claude:
                return [NSString(string: "~/.local/bin/claude").expandingTildeInPath,
                        "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            case .codex:
                // The desktop app and CLI share CODEX_HOME, including the model
                // cache. Prefer the desktop-bundled executable when available
                // so the reader version matches the process that wrote it.
                return ["/Applications/ChatGPT.app/Contents/Resources/codex",
                        NSString(string: "~/.local/bin/codex").expandingTildeInPath,
                        NSString(string: "~/.npm-global/bin/codex").expandingTildeInPath,
                        "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            }
        }

        var installHint: String {
            switch self {
            case .whisper: return "brew install whisper-cpp"
            case .claude:  return "claude.com/claude-code"
            case .codex:   return "npm install -g @openai/codex，然后运行 codex login"
            }
        }
    }

    static let modelDirectory = URL(
        fileURLWithPath: NSString(string: "~/.cache/whisper.cpp").expandingTildeInPath)

    static let transcriptionModel = "ggml-large-v3-turbo.bin"
    static let vadModel = "ggml-silero-v5.1.2.bin"

    // Pin immutable upstream revisions and verify every new download before it
    // replaces an installed model.
    static let transcriptionModelSHA256 =
        "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    static let vadModelSHA256 =
        "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"

    static let transcriptionModelURL =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/782613cdb31f03b62609e52ed2c9eb0d150166aa/\(transcriptionModel)"
    static let vadModelURL =
        "https://huggingface.co/ggml-org/whisper-vad/resolve/e5614ed76a5dd4b03fad5068c89efcd2617a9d1e/\(vadModel)"

    static func path(for tool: Tool) -> String? {
        if let override = UserDefaults.standard.string(forKey: "toolPath.\(tool.rawValue)"),
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        for candidate in tool.candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return which(tool.displayName)
    }

    static func require(_ tool: Tool) throws -> String {
        guard let path = path(for: tool) else { throw ToolError.missing(tool) }
        return path
    }

    static func modelPath() -> String? {
        let url = modelDirectory.appendingPathComponent(transcriptionModel)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    static func vadModelPath() -> String? {
        let url = modelDirectory.appendingPathComponent(vadModel)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// Falls back to a login shell so PATH-only installs are still found.
    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

enum ToolError: LocalizedError {
    case missing(ToolLocator.Tool)
    case modelMissing
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .missing(let tool):
            return "找不到 \(tool.displayName)。安装：\(tool.installHint)"
        case .modelMissing:
            return "缺少识别模型，请在设置里下载。"
        case .noAPIKey:
            return "未设置 Anthropic API key。"
        }
    }
}
