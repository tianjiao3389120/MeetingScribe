import XCTest
@testable import MeetingScribe

final class DiarizerUpgradeTests: XCTestCase {
    func testLegacyCacheWithoutEmbeddingsIsRejected() throws {
        let data = Data(#"{"segments":[{"start":0,"end":1,"speaker":0}]}"#.utf8)
        let decoded = try JSONDecoder().decode(Diarization.self, from: data)

        XCTAssertFalse(decoded.segments.isEmpty)
        XCTAssertTrue(decoded.embeddings.isEmpty,
                      "A legacy cache must be identifiable so the runner recomputes it")
    }
}
