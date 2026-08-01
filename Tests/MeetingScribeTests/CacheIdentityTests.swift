import XCTest
@testable import MeetingScribe

final class CacheIdentityTests: XCTestCase {
    func testAlgorithmVersionChangesCacheIdentity() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-cache-test-\(UUID().uuidString)")
        try Data("sample media".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = TranscriptCache.key(for: url, language: "zh", glossary: "术语", version: "v1")
        let second = TranscriptCache.key(for: url, language: "zh", glossary: "术语", version: "v2")
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)
    }
}
