import XCTest
@testable import MeetingScribe

final class EndpointSecurityTests: XCTestCase {
    func testHTTPSRemoteEndpointIsAccepted() throws {
        let client = OpenAICompatibleClient(
            baseURL: "https://example.com/v1/", apiKey: nil,
            model: "test", supportsVision: false)
        XCTAssertEqual(try client.endpoint().absoluteString,
                       "https://example.com/v1/chat/completions")
    }

    func testLocalHTTPIsAccepted() throws {
        let client = OpenAICompatibleClient(
            baseURL: "http://127.0.0.1:11434/v1", apiKey: nil,
            model: "test", supportsVision: false)
        XCTAssertNoThrow(try client.endpoint())
    }

    func testRemoteHTTPIsRejected() {
        let client = OpenAICompatibleClient(
            baseURL: "http://api.example.com/v1", apiKey: "secret",
            model: "test", supportsVision: false)
        XCTAssertThrowsError(try client.endpoint()) { error in
            guard case OpenAICompatibleClient.Failure.insecureRemoteURL = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNotNil(OpenAICompatibleClient.securityWarning(for: client.baseURL))
    }

    func testOpenAIPresetUsesOfficialEndpointAndVisionModels() throws {
        XCTAssertEqual(ProviderPreset.openAI.baseURL, "https://api.openai.com/v1")
        XCTAssertTrue(ProviderPreset.all.contains { $0.id == "openai" })
        XCTAssertTrue(ProviderPreset.openAI.models.allSatisfy(\.supportsVision))

        let client = OpenAICompatibleClient(
            baseURL: ProviderPreset.openAI.baseURL, apiKey: "secret",
            model: ProviderPreset.openAI.models[0].id, supportsVision: true)
        XCTAssertEqual(try client.endpoint().absoluteString,
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertTrue(client.usesOpenAICompletionTokenParameter)
    }

    func testOnlyVerifiedAPIProvidersAreExposed() {
        XCTAssertEqual(ProviderPreset.all.map(\.id), ["openai", "zhipu"])
        XCTAssertEqual(ProviderPreset.preset(id: "unsupported").id, "openai")
    }

    func testResponsesCompletedEventTextCanBeRecovered() {
        let response: [String: Any] = [
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": "生成完成"]],
            ]],
        ]
        XCTAssertEqual(OpenAICompatibleClient.responseOutputText(from: response), "生成完成")
    }

    func testResponsesCompletedEventIgnoresNonTextOutputItems() {
        let response: [String: Any] = [
            "output": [
                ["type": "reasoning", "summary": []],
                ["type": "message", "content": [
                    ["type": "output_text", "text": "最终纪要"],
                ]],
            ],
        ]
        XCTAssertEqual(OpenAICompatibleClient.responseOutputText(from: response), "最终纪要")
    }
}
