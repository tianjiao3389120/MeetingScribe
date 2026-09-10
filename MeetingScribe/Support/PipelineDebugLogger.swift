import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Terminal-first diagnostics for the meeting pipeline. When disabled, callers keep a nil
/// session and pay no formatting, file IO, or polling cost.
final class PipelineDebugSession: @unchecked Sendable {
    let directory: URL
    let logURL: URL
    let continueURL: URL
    let pausesAtNodeStart: Bool

    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private var lastPercentByNode: [String: Int] = [:]
    private var engineSequence = 0
    private var engineFiles: [String: (stdout: URL, stderr: URL)] = [:]
    private var lastEnginePercent: [String: Int] = [:]
    private var nodeStartedAt: [String: Date] = [:]
    private var engineStartedAt: [String: Date] = [:]
    private var engineNode: [String: String] = [:]
    private var activeNode: String?
    private var modelTokensByNode: [String: Int] = [:]
    private let runStartedAt = Date()
    private var lastTranscriptSecondByNode: [String: Int] = [:]
    private var lastTranscriptLogAtByNode: [String: Date] = [:]
    private var lastRunSummaryStatus: String?

    init(root: URL? = nil, pausesAtNodeStart: Bool) throws {
        let base = root ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/Debug", isDirectory: true)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        directory = base.appendingPathComponent("run-\(stamp)-\(UUID().uuidString.prefix(8))",
                                                isDirectory: true)
        logURL = directory.appendingPathComponent("pipeline.log")
        continueURL = directory.appendingPathComponent("continue")
        self.pausesAtNodeStart = pausesAtNodeStart
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let latest = base.appendingPathComponent("latest.log")
        try? FileManager.default.removeItem(at: latest)
        try? FileManager.default.createSymbolicLink(at: latest, withDestinationURL: logURL)
        write(type: "DEBUG SESSION", node: "流水线",
              detail: "日志：\(logURL.path)\n产物目录：\(directory.path)")
    }

    func beginNode(_ node: String, input: @autoclosure () -> String) async throws {
        lock.withLock {
            nodeStartedAt[node] = Date()
            activeNode = node
        }
        write(type: "NODE INPUT", node: node, detail: input())
        guard pausesAtNodeStart else { return }
        try? FileManager.default.removeItem(at: continueURL)
        write(type: "TERMINAL WAIT", node: node,
              detail: "节点已暂停，等待终端确认。\n执行：\ntouch \"\(continueURL.path)\"")
        while !FileManager.default.fileExists(atPath: continueURL.path) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
        }
        write(type: "TERMINAL CONTINUE RECEIVED", node: node,
              detail: "已检测到 continue 文件，节点继续执行。")
        try? FileManager.default.removeItem(at: continueURL)
    }

    func progress(_ node: String, _ detail: @autoclosure () -> String) {
        write(type: "NODE PROGRESS", node: node, detail: detail())
    }

    func transcriptProgress(_ node: String, seconds: TimeInterval, duration: TimeInterval) {
        let second = max(Int(seconds.rounded(.down)), 0)
        let now = Date()
        lock.lock()
        let advanced = second - (lastTranscriptSecondByNode[node] ?? -10)
        let elapsed = now.timeIntervalSince(lastTranscriptLogAtByNode[node] ?? .distantPast)
        let shouldLog = advanced >= 10 || elapsed >= 5 || seconds >= duration
        if shouldLog {
            lastTranscriptSecondByNode[node] = second
            lastTranscriptLogAtByNode[node] = now
        }
        lock.unlock()
        guard shouldLog else { return }
        let percent = Int((min(max(seconds / max(duration, 1), 0), 1) * 100).rounded())
        write(type: "NODE PROGRESS", node: node,
              detail: "已转录 \(TranscriptSegment.timecode(seconds)) / \(TranscriptSegment.timecode(duration))（\(percent)%）")
    }

    func cache(_ node: String, hit: Bool, detail: String) {
        write(type: "CACHE \(hit ? "HIT" : "MISS")", node: node, detail: detail)
    }

    /// Append-only logs cannot safely redraw one terminal line. Emit one visual bar only when
    /// the rounded percentage changes, keeping `tail -f` readable and the audit trail complete.
    func progressPercent(_ node: String, label: String, fraction: Double) {
        let percent = min(max(Int((fraction * 100).rounded()), 0), 100)
        lock.lock()
        let changed = lastPercentByNode[node] != percent
        if changed { lastPercentByNode[node] = percent }
        lock.unlock()
        guard changed else { return }
        let filled = percent / 5
        let bar = String(repeating: "█", count: filled)
            + String(repeating: "░", count: 20 - filled)
        write(type: "NODE PROGRESS", node: node,
              detail: "\(label) [\(bar)] \(percent)%")
    }

    func endNode(_ node: String, output: @autoclosure () -> String) {
        lock.lock()
        let started = nodeStartedAt.removeValue(forKey: node)
        if activeNode == node { activeNode = nil }
        lock.unlock()
        let timing = started.map { "耗时：\(Self.duration(Date().timeIntervalSince($0)))\n" } ?? ""
        write(type: "NODE OUTPUT", node: node, detail: timing + output())
    }

    func engineStart(tool: String, arguments: [String]) {
        lock.lock()
        engineSequence += 1
        let base = URL(fileURLWithPath: tool).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        let prefix = String(format: "engine-%02d-%@", engineSequence, base)
        let files = (directory.appendingPathComponent("\(prefix)-stdout.log"),
                     directory.appendingPathComponent("\(prefix)-stderr.log"))
        engineFiles[tool] = files
        lastEnginePercent[tool] = nil
        engineStartedAt[tool] = Date()
        engineNode[tool] = activeNode ?? "未归属节点"
        FileManager.default.createFile(atPath: files.0.path, contents: nil)
        FileManager.default.createFile(atPath: files.1.path, contents: nil)
        lock.unlock()
        write(type: "ENGINE START", node: tool,
              detail: "工具路径：\(tool)\n参数：\(arguments.isEmpty ? "<空>" : arguments.joined(separator: " "))\nstdout 文件：\(files.0.path)\nstderr 文件：\(files.1.path)")
    }

    func engineStderr(tool: String, text: String) {
        lock.lock()
        if let url = engineFiles[tool]?.stderr,
           let data = text.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
        }
        lock.unlock()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let progress = engineProgress(line) {
                lock.lock()
                let changed = lastEnginePercent[tool] != progress.percent
                if changed { lastEnginePercent[tool] = progress.percent }
                lock.unlock()
                if changed {
                    write(type: "ENGINE STDERR", node: tool,
                          detail: "PROGRESS \(progress.percent)%（\(progress.done)/\(progress.total)）")
                }
            } else if shouldMirrorEngineLine(line) {
                write(type: "ENGINE STDERR", node: tool, detail: line)
            }
        }
    }

    func engineEnd(tool: String, exitCode: Int32, stdout: String, stderr: String) {
        lock.lock()
        let files = engineFiles.removeValue(forKey: tool)
        lastEnginePercent[tool] = nil
        let started = engineStartedAt.removeValue(forKey: tool)
        let owner = engineNode.removeValue(forKey: tool) ?? "未归属节点"
        lock.unlock()
        if let files {
            try? stdout.write(to: files.stdout, atomically: true, encoding: .utf8)
            try? stderr.write(to: files.stderr, atomically: true, encoding: .utf8)
        }
        let stdoutSummary = engineSummary(stdout, file: files?.stdout)
        let stderrSummary = engineSummary(stderr, file: files?.stderr)
        let tokens = tokenUsage(in: stdout + "\n" + stderr)
        if tokens > 0 {
            lock.lock(); modelTokensByNode[owner, default: 0] += tokens; lock.unlock()
        }
        let elapsed = started.map { Self.duration(Date().timeIntervalSince($0)) } ?? "<未知>"
        write(type: "ENGINE END", node: tool,
              detail: "所属节点：\(owner)\n耗时：\(elapsed)\n退出码：\(exitCode)\nToken：\(tokens > 0 ? String(tokens) : "<不可用>")\nstdout：\n\(stdoutSummary)\nstderr：\n\(stderrSummary)")
    }

    func imageSelection(_ detail: String) {
        write(type: "IMAGE SELECTION", node: "关键画面", detail: detail)
    }

    func qualitySummary(_ detail: String) {
        write(type: "QUALITY SUMMARY", node: "纪要", detail: detail)
    }

    func runSummary(status: String, cache: String, screen: String, extra: String = "") {
        lock.lock()
        guard lastRunSummaryStatus != status else { lock.unlock(); return }
        lastRunSummaryStatus = status
        let tokens = modelTokensByNode
        let engineCount = engineSequence
        lock.unlock()
        let tokenLines = tokens.isEmpty ? "Token：<不可用>" : tokens.sorted { $0.key < $1.key }
            .map { "Token · \($0.key)：\($0.value)" }.joined(separator: "\n")
        let total = tokens.values.reduce(0, +)
        write(type: "RUN SUMMARY", node: "流水线", detail: """
        状态：\(status)
        总耗时：\(Self.duration(Date().timeIntervalSince(runStartedAt)))
        缓存：\(cache)
        外部引擎：\(engineCount) 次
        \(tokenLines)
        Token · 合计：\(total > 0 ? String(total) : "<不可用>")
        画面：\(screen)
        \(extra)
        """)
    }

    @discardableResult
    func writeText(_ name: String, _ text: String) -> URL? {
        let url = directory.appendingPathComponent(name)
        do { try text.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }

    @discardableResult
    func writeData(_ name: String, _ data: Data) -> URL? {
        let url = directory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic); return url }
        catch { return nil }
    }

    @discardableResult
    func copyFile(_ source: URL, name: String) -> URL? {
        let destination = directory.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch { return nil }
    }

    @discardableResult
    func writePNG(_ image: CGImage, name: String) -> URL? {
        let url = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    private func visible(_ value: String) -> String {
        value.isEmpty ? "<空>" : value
    }

    private func engineProgress(_ line: String) -> (done: Int, total: Int, percent: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "PROGRESS",
              let done = Int(parts[1]), let total = Int(parts[2]), total > 0 else { return nil }
        return (done, total, min(max(Int((Double(done) / Double(total) * 100).rounded()), 0), 100))
    }

    private func engineSummary(_ value: String, file: URL?) -> String {
        guard !value.isEmpty else { return "<空>" }
        guard let file else { return value }
        let tail = value.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(12).joined(separator: "\n")
        return "完整内容：\(file.path)\n大小：\(value.utf8.count) 字节\n末尾摘要：\n\(tail)"
    }

    private func shouldMirrorEngineLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["error", "fatal", "warning", "exception", "traceback", "失败", "警告"]
            .contains(where: lower.contains)
    }

    private func tokenUsage(in value: String) -> Int {
        let lines = value.components(separatedBy: .newlines)
        for index in lines.indices where lines[index].lowercased().contains("tokens used") {
            for candidate in lines.dropFirst(index + 1).prefix(3) {
                let cleaned = candidate.replacingOccurrences(of: ",", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let number = Int(cleaned) { return number }
            }
        }
        return 0
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.3f 秒", seconds) }
        if seconds < 60 { return String(format: "%.1f 秒", seconds) }
        let whole = Int(seconds.rounded())
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    private func write(type: String, node: String, detail: String) {
        lock.lock(); defer { lock.unlock() }
        let entry = "[\(formatter.string(from: Date()))] [\(type) · \(node)]\n\(visible(detail))\n\n"
        guard let data = entry.data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { }
    }
}

/// Lets low-level engine wrappers log without adding debug parameters to production APIs.
enum PipelineDebugRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: PipelineDebugSession?

    static var active: PipelineDebugSession? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    static func install(_ session: PipelineDebugSession?) {
        lock.lock(); stored = session; lock.unlock()
    }
}
