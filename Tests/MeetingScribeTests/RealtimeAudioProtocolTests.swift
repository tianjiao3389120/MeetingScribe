import Darwin
import XCTest
@testable import MeetingScribe

final class RealtimeAudioProtocolTests: XCTestCase {
    func testRealtimeQualityMapsToSupportedTranscriptionModels() {
        XCTAssertEqual(RealtimeTranscriptionQuality.realtime.model, "gpt-realtime-whisper")
        XCTAssertEqual(RealtimeTranscriptionQuality.accurate.model, "gpt-4o-transcribe")
    }

    func testRealtimeSessionUsesServerVADAndPrompt() throws {
        let service = try OpenAIRealtimeTranscriptionService(
            apiKey: "test-key", model: "gpt-realtime-whisper",
            language: "zh", prompt: "HIDS Falcon")
        let session = try XCTUnwrap(service.sessionUpdatePayload["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        let vad = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-realtime-whisper")
        XCTAssertEqual(transcription["language"] as? String, "zh")
        XCTAssertEqual(transcription["prompt"] as? String, "HIDS Falcon")
        XCTAssertEqual(vad["type"] as? String, "server_vad")
        XCTAssertEqual(vad["silence_duration_ms"] as? Int, 800)
    }

    func testStopCommandRoundTrip() {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer {
            Darwin.close(sockets[0])
            Darwin.close(sockets[1])
        }
        let clientSocket = sockets[0]
        let serverSocket = sockets[1]

        let received = expectation(description: "Helper receives stop command")
        DispatchQueue.global().async {
            XCTAssertTrue(BlackHoleAudioProtocol.waitForStop(on: serverSocket))
            received.fulfill()
        }

        XCTAssertTrue(BlackHoleAudioProtocol.sendStop(to: clientSocket))
        wait(for: [received], timeout: 1)
    }

    func testClosedSocketDoesNotCountAsStopAcknowledgement() {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        Darwin.close(sockets[0])
        defer { Darwin.close(sockets[1]) }

        XCTAssertFalse(BlackHoleAudioProtocol.waitForStop(on: sockets[1]))
    }
}
