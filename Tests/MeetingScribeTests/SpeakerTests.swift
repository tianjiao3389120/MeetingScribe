import XCTest
@testable import MeetingScribe

final class SpeakerTests: XCTestCase {
    func testSpeakerUsesLargestOverlapAndLabelsByProminence() {
        let value = Diarization(segments: [
            SpeakerSegment(start: 0, end: 8, speaker: 7),
            SpeakerSegment(start: 8, end: 12, speaker: 3),
            SpeakerSegment(start: 12, end: 14, speaker: 7),
        ])

        XCTAssertEqual(value.speaker(from: 7, to: 10), 3)
        XCTAssertEqual(value.labels[7], "A")
        XCTAssertEqual(value.labels[3], "B")
        XCTAssertEqual(value.displayName(for: 7), "说话人A")
    }

    func testKnownNameOverridesAnonymousLabel() {
        let value = Diarization(
            segments: [SpeakerSegment(start: 0, end: 2, speaker: 9)],
            names: [9: "张三"]
        )
        XCTAssertEqual(value.displayName(for: 9), "张三")
    }

    func testVoiceSimilarityRejectsMismatchedDimensions() {
        XCTAssertEqual(VoiceProfileStore.similarity([1, 0], [1, 0]), 1, accuracy: 0.001)
        XCTAssertEqual(VoiceProfileStore.similarity([1], [1, 0]), 0)
    }

    func testMergingVoiceSamplesRenormalizesRunningMean() {
        var profile = VoiceProfile(name: "测试", embedding: [1, 0])
        profile.merge([0, 1])

        XCTAssertEqual(profile.sampleCount, 2)
        XCTAssertEqual(profile.embedding[0], 0.7071, accuracy: 0.001)
        XCTAssertEqual(profile.embedding[1], 0.7071, accuracy: 0.001)
    }

    func testLegacyVoiceProfileDecodesWithoutReferenceClip() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"测试","embedding":[1,0],"sampleCount":1,"updatedAt":0,"note":""}"#.utf8)
        let profile = try JSONDecoder().decode(VoiceProfile.self, from: data)

        XCTAssertNil(profile.referenceClip)
    }

    func testLegacyDiarizationCacheDecodesWithoutVoiceprints() throws {
        let data = Data(#"{"segments":[{"start":0,"end":2,"speaker":4}]}"#.utf8)
        let value = try JSONDecoder().decode(Diarization.self, from: data)

        XCTAssertEqual(value.segments.count, 1)
        XCTAssertTrue(value.embeddings.isEmpty)
        XCTAssertTrue(value.names.isEmpty)
    }
}
