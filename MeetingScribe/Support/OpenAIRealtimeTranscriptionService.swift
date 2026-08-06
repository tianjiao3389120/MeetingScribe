import Foundation

/// Minimal WebSocket client for OpenAI Realtime Transcription.
/// The capture service owns audio; this type only transports PCM and reports text.
final class OpenAIRealtimeTranscriptionService: @unchecked Sendable {
    private static let commitIntervalBytes = 24_000 * 2 * 5

    enum Event: Sendable {
        case delta(String)
        case completed(String)
        case failed(String)
        case status(String)
    }

    enum Failure: LocalizedError {
        case missingAPIKey
        case invalidEndpoint
        case notConnected
        case server(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "未设置 OPENAI_API_KEY。"
            case .invalidEndpoint: return "Realtime Transcription WebSocket 地址无效。"
            case .notConnected: return "Realtime Transcription 尚未连接。"
            case .server(let detail): return detail
            }
        }
    }

    private let apiKey: String
    private let model: String
    private let language: String?
    private let prompt: String?
    private let delegate: WebSocketDelegate
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var bytesSent = 0
    private var uncommittedBytes = 0

    init(apiKey: String, model: String = "gpt-live-transcribe",
         language: String? = nil, prompt: String? = nil) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure.missingAPIKey }
        guard let endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription"),
              endpoint.scheme == "wss" else { throw Failure.invalidEndpoint }
        self.apiKey = key
        self.model = model
        self.language = language
        self.prompt = prompt
        let delegate = WebSocketDelegate()
        self.delegate = delegate
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func connect() async throws {
        guard let endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            throw Failure.invalidEndpoint
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        try await delegate.waitForOpen()

        do {
            // The server-created event is read by the receiver task. Send the
            // configuration immediately after the handshake so no first-event
            // timing assumption can block the session.
            try await sendJSON([
                "type": "session.update",
                "session": [
                    "type": "transcription",
                    "audio": [
                        "input": [
                            "format": ["type": "audio/pcm", "rate": 24000],
                            "transcription": transcriptionOptions,
                        ],
                    ],
                ],
            ])
        } catch {
            throw Failure.server("WebSocket 已打开，但发送 session.update 失败：\(describe(error))")
        }
    }

    func sendAudio(_ data: Data) async throws {
        guard socket != nil else { throw Failure.notConnected }
        guard !data.isEmpty else { return }
        try await sendJSON([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ])
        bytesSent += data.count
        uncommittedBytes += data.count
        if uncommittedBytes >= Self.commitIntervalBytes {
            try await commit()
        }
    }

    func commit() async throws {
        // The API rejects buffers shorter than 100 ms. Timer-based commits may
        // already have flushed the final audio before shutdown.
        guard uncommittedBytes >= 24_000 * 2 / 10 else { return }
        try await sendJSON(["type": "input_audio_buffer.commit"])
        uncommittedBytes = 0
    }

    func receive() async throws -> Event {
        guard let socket else { throw Failure.notConnected }
        let message = try await socket.receive()
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return .status("收到非文本 WebSocket 消息")
        }

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            return .delta(textValue(in: object, keys: ["delta", "text"]))
        case "conversation.item.input_audio_transcription.segment":
            return .delta(textValue(in: object, keys: ["text", "delta"]))
        case "conversation.item.input_audio_transcription.completed":
            return .completed(textValue(in: object, keys: ["transcript", "text", "delta"]))
        case "conversation.item.input_audio_transcription.failed":
            let error = object["error"] as? [String: Any]
            return .failed(error?["message"] as? String ?? "转写失败")
        case "error":
            let error = object["error"] as? [String: Any]
            throw Failure.server(error?["message"] as? String ?? "Realtime API 返回错误")
        case "session.updated", "transcription_session.updated":
            return .status("Realtime Transcription 会话已就绪")
        case "conversation.item.done":
            if let item = object["item"] as? [String: Any],
               let content = item["content"] as? [[String: Any]],
               let part = content.first {
                let text = textValue(in: part, keys: ["transcript", "text", "delta"])
                if !text.isEmpty { return .completed(text) }
            }
            return .status("")
        default:
            return .status("")
        }
    }

    func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session.invalidateAndCancel()
    }

    var sentBytes: Int { bytesSent }

    private var transcriptionOptions: [String: Any] {
        var value: [String: Any] = ["model": model]
        if let language, !language.isEmpty { value["language"] = language }
        if let prompt, !prompt.isEmpty { value["prompt"] = prompt }
        return value
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let socket else { throw Failure.notConnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.server("Realtime 请求编码失败")
        }
        try await socket.send(.string(text))
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var detail = "\(nsError.localizedDescription) [\(nsError.domain)/\(nsError.code)]"
        if let url = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            detail += " url=\(url)"
        }
        return detail
    }

    private func textValue(in object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let text = object[key] as? String, !text.isEmpty { return text }
        }
        return ""
    }
}

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private var openContinuation: CheckedContinuation<Void, Error>?

    func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            openContinuation = continuation
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        openContinuation?.resume()
        openContinuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        openContinuation?.resume(throwing: Failure.connection(error.localizedDescription))
        openContinuation = nil
    }

    private enum Failure: LocalizedError {
        case connection(String)

        var errorDescription: String? {
            switch self {
            case .connection(let detail): return "WebSocket 握手失败：\(detail)"
            }
        }
    }
}
