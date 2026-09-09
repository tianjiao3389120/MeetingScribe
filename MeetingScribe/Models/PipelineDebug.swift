import Foundation
import CoreGraphics
import Observation

enum PipelineDebugPhase: String {
    case before = "运行前"
    case after = "运行后"
}

struct PipelineDebugEvent: Identifiable {
    let id = UUID()
    let node: String
    let phase: PipelineDebugPhase
    let payload: String
    let image: CGImage?
    let createdAt = Date()
}

/// In-memory inspection and pause gate for one pipeline run. It intentionally
/// never writes payloads to the meeting library or to disk.
@Observable
@MainActor
final class PipelineDebugSession {
    @MainActor private static var activeSession: PipelineDebugSession?
    private(set) var events: [PipelineDebugEvent] = []
    private(set) var pausedNode: String?
    private(set) var pausedPhase: PipelineDebugPhase?
    private(set) var logURL: URL?
    private(set) var artifactDirectory: URL?
    private var continuation: CheckedContinuation<Void, Never>?
    private var logHandle: FileHandle?

    var isPaused: Bool { continuation != nil }

    func reset() {
        let value = continuation
        continuation = nil
        value?.resume()
        events = []
        pausedNode = nil
        pausedPhase = nil
        logHandle = nil
        logURL = nil
        artifactDirectory = nil
        if Settings.shared.pipelineDebugEnabled {
            let id = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let runID = "\(id)-\(UUID().uuidString.prefix(8))"
            let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/MeetingScribe", isDirectory: true)
            let artifacts = AppDirectories.applicationSupport
                .appendingPathComponent("DebugRuns/\(runID)", isDirectory: true)
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            let url = logs.appendingPathComponent("debug-\(runID).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logURL = url
            artifactDirectory = artifacts
            logHandle = try? FileHandle(forWritingTo: url)
            Self.activeSession = self
            writeLog("RUN", "日志：\(url.path)\n调试文件：\(artifacts.path)")
        } else if Self.activeSession === self {
            Self.activeSession = nil
        }
    }

    @MainActor static func current() -> PipelineDebugSession? { activeSession }

    func writeLog(_ title: String, _ body: String) {
        guard let data = "\n===== \(title) =====\n\(body)\n".data(using: .utf8) else { return }
        try? logHandle?.seekToEnd()
        try? logHandle?.write(contentsOf: data)
    }

    func writeArtifact(_ data: Data, name: String) -> URL? {
        guard let directory = artifactDirectory else { return nil }
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            writeLog("ARTIFACT", url.path)
            return url
        } catch {
            writeLog("ARTIFACT ERROR", "\(url.path)：\(error.localizedDescription)")
            return nil
        }
    }

    func before(_ node: String, input: String) async {
        guard Settings.shared.pipelineDebugEnabled else { return }
        append(node, .before, input)
        if Settings.shared.pipelineDebugPauseBefore {
            await pause(node, phase: .before)
        }
    }

    func after(_ node: String, output: String, image: CGImage? = nil) async {
        guard Settings.shared.pipelineDebugEnabled else { return }
        append(node, .after, output, image: image)
        if Settings.shared.pipelineDebugPauseAfter {
            await pause(node, phase: .after)
        }
    }

    func resume() {
        pausedNode = nil
        pausedPhase = nil
        let value = continuation
        continuation = nil
        value?.resume()
    }

    private func append(_ node: String, _ phase: PipelineDebugPhase, _ payload: String,
                        image: CGImage? = nil) {
        events.append(PipelineDebugEvent(node: node, phase: phase, payload: payload, image: image))
        writeLog("\(phase.rawValue) · \(node)", payload)
        if events.count > 300 { events.removeFirst(events.count - 300) }
    }

    private func pause(_ node: String, phase: PipelineDebugPhase) async {
        pausedNode = node
        pausedPhase = phase
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
    }
}
