import Foundation

/// Thin async wrapper around Process, used for whisper-cli and the claude CLI.
enum Shell {

    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    enum Failure: LocalizedError {
        case launch(String, Error)
        case exit(String, Int32, String)
        case timedOut(String, TimeInterval)

        var errorDescription: String? {
            switch self {
            case .launch(let tool, let err):
                return "无法启动 \(tool)：\(err.localizedDescription)"
            case .exit(let tool, let code, let stderr):
                let tail = stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
                return "\(tool) 退出码 \(code)\n\(tail)"
            case .timedOut(let tool, let seconds):
                return "\(tool) 超过 \(TranscriptSegment.humanDuration(seconds)) 未返回，已终止。"
            }
        }
    }

    /// `onStderrLine` receives stderr as it arrives — whisper reports progress
    /// there, which is what drives the progress bar.
    ///
    /// `timeout` guards against a child that never exits: without it a wedged
    /// `claude` process leaves the UI stuck on "生成纪要" forever.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        stdin: String? = nil,
        timeout: TimeInterval? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {

        let process = Process()
        let controller = ProcessController(process)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        let collector = StreamCollector()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.appendOut(data)
            if let onStdoutLine, let chunk = String(data: data, encoding: .utf8) {
                for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onStdoutLine(trimmed) }
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.appendErr(data)
            if let onStderrLine, let chunk = String(data: data, encoding: .utf8) {
                for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onStderrLine(trimmed) }
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw Failure.launch((executable as NSString).lastPathComponent, error)
        }

        if let stdin, let data = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        // Terminate a child that outstays the deadline, then let the normal
        // exit path collect whatever it produced.
        let watchdog: Task<Void, Never>? = timeout.map { seconds in
            Task {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
                controller.terminate(reason: .timedOut)
            }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } onCancel: {
            controller.terminate(reason: .cancelled)
        }
        watchdog?.cancel()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            collector.appendOut(rest)
        }
        if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            collector.appendErr(rest)
        }

        switch controller.stopReason {
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw Failure.timedOut((executable as NSString).lastPathComponent, timeout ?? 0)
        case nil:
            break
        }

        return Result(status: process.terminationStatus,
                      stdout: collector.stdoutString,
                      stderr: collector.stderrString)
    }

    @discardableResult
    static func check(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        stdin: String? = nil,
        timeout: TimeInterval? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let result = try await run(executable, arguments, environment: environment,
                                   stdin: stdin, timeout: timeout,
                                   onStdoutLine: onStdoutLine,
                                   onStderrLine: onStderrLine)
        guard result.ok else {
            throw Failure.exit((executable as NSString).lastPathComponent,
                               result.status, result.stderr)
        }
        return result
    }
}

/// `Process` is not Sendable, but all termination decisions are serialized by
/// this lock-backed owner. It also records why we stopped the child, so a crash
/// signal is not mistaken for a timeout.
private final class ProcessController: @unchecked Sendable {
    enum StopReason { case cancelled, timedOut }

    private let process: Process
    private let lock = NSLock()
    private var reason: StopReason?

    init(_ process: Process) { self.process = process }

    var stopReason: StopReason? {
        lock.lock(); defer { lock.unlock() }
        return reason
    }

    func terminate(reason: StopReason) {
        lock.lock()
        guard self.reason == nil else { lock.unlock(); return }
        self.reason = reason
        let isRunning = process.isRunning
        lock.unlock()

        if isRunning { process.terminate() }

        // A child may ignore SIGTERM. Do not leave cancellation or timeout
        // waiting forever for its termination handler.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// Readability handlers fire on arbitrary queues, so the buffers need a lock.
private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ data: Data) { lock.lock(); out.append(data); lock.unlock() }
    func appendErr(_ data: Data) { lock.lock(); err.append(data); lock.unlock() }

    var stdoutString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderrString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}
