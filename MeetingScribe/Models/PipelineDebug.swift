import Foundation
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
    let createdAt = Date()
}

/// In-memory inspection and pause gate for one pipeline run. It intentionally
/// never writes payloads to the meeting library or to disk.
@Observable
@MainActor
final class PipelineDebugSession {
    private(set) var events: [PipelineDebugEvent] = []
    private(set) var pausedNode: String?
    private(set) var pausedPhase: PipelineDebugPhase?
    private var continuation: CheckedContinuation<Void, Never>?

    var isPaused: Bool { continuation != nil }

    func reset() {
        events = []
        pausedNode = nil
        pausedPhase = nil
        continuation = nil
    }

    func before(_ node: String, input: String) async {
        guard Settings.shared.pipelineDebugEnabled else { return }
        append(node, .before, input)
        if Settings.shared.pipelineDebugPauseBefore {
            await pause(node, phase: .before)
        }
    }

    func after(_ node: String, output: String) async {
        guard Settings.shared.pipelineDebugEnabled else { return }
        append(node, .after, output)
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

    private func append(_ node: String, _ phase: PipelineDebugPhase, _ payload: String) {
        events.append(PipelineDebugEvent(node: node, phase: phase, payload: payload))
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
