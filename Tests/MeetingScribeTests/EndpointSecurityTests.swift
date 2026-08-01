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
}
