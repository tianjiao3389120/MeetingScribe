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

    func testConfirmedAffiliationAndRoleAreIncludedInPromptLabel() {
        let value = Diarization(
            segments: [SpeakerSegment(start: 0, end: 2, speaker: 9)],
            names: [9: "张三"],
            roles: [9: SpeakerRole(affiliation: .customer, meetingRole: .leader)])

        XCTAssertEqual(value.displayName(for: 9), "张三｜客户｜领导")
    }

    func testRoleSelectionPropagatesOnlyToConfirmedSameNameClusters() {
        let role = SpeakerRole(affiliation: .ours, meetingRole: .engineer)
        let result = SpeakerRole.applying(
            role, to: 1,
            names: [1: " Joey ", 2: "joey", 3: "Joey Chen"],
            roles: [4: SpeakerRole(affiliation: .customer, meetingRole: .leader)])

        XCTAssertEqual(result[1], role)
        XCTAssertEqual(result[2], role)
        XCTAssertNil(result[3])
        XCTAssertEqual(result[4]?.meetingRole, .leader)
    }

    func testLegacyDiarizationDecodesWithoutSpeakerRoles() throws {
        let data = #"{"segments":[{"start":0,"end":1,"speaker":0}],"names":{"0":"张三"}}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Diarization.self, from: data)
        XCTAssertTrue(decoded.roles.isEmpty)
    }

    func testVoiceSimilarityRejectsMismatchedDimensions() {
        XCTAssertEqual(VoiceProfileStore.similarity([1, 0], [1, 0]), 1, accuracy: 0.001)
        XCTAssertEqual(VoiceProfileStore.similarity([1], [1, 0]), 0)
    }

    func testVoiceMatchingAllowsSplitClustersToResolveToSamePerson() {
        let profiles = [
            VoiceProfile(name: "郑云凤", embedding: [1, 0]),
            VoiceProfile(name: "Joey", embedding: [0, 1]),
        ]

        let matches = VoiceProfileStore.match(
            embeddings: ["2": [0.99, 0.01], "4": [0.98, 0.02]],
            profiles: profiles)

        XCTAssertEqual(matches[2], "郑云凤")
        XCTAssertEqual(matches[4], "郑云凤")
    }

    func testMergingVoiceSamplesRenormalizesRunningMean() {
        var profile = VoiceProfile(name: "测试", embedding: [1, 0])
        profile.merge([0, 1])

        XCTAssertEqual(profile.sampleCount, 2)
        XCTAssertEqual(profile.embedding[0], 0.7071, accuracy: 0.001)
        XCTAssertEqual(profile.embedding[1], 0.7071, accuracy: 0.001)
        XCTAssertEqual(profile.representativeEmbeddings.count, 2)
    }

    func testNearDuplicateVoiceSamplesDoNotConsumeRepresentativeSlots() {
        var profile = VoiceProfile(name: "测试", embedding: [1, 0])
        profile.merge([0.999, 0.001])

        XCTAssertEqual(profile.sampleCount, 2)
        XCTAssertEqual(profile.representativeEmbeddings.count, 1)
    }

    func testRepresentativeSampleImprovesCrossEnvironmentMatchWithoutIgnoringCentroid() {
        let profile = VoiceProfile(
            name: "测试", embedding: [0.8, 0.6], sampleCount: 2,
            representativeEmbeddings: [[1, 0], [0, 1]])

        XCTAssertEqual(VoiceProfileStore.matchScore([1, 0], profile: profile), 0.94,
                       accuracy: 0.001)
    }

    func testLegacyVoiceProfileDecodesWithoutReferenceClip() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"测试","embedding":[1,0],"sampleCount":1,"updatedAt":0,"note":""}"#.utf8)
        let profile = try JSONDecoder().decode(VoiceProfile.self, from: data)

        XCTAssertNil(profile.referenceClip)
        XCTAssertEqual(profile.representativeEmbeddings, [[1, 0]])
    }

    func testLegacyDiarizationCacheDecodesWithoutVoiceprints() throws {
        let data = Data(#"{"segments":[{"start":0,"end":2,"speaker":4}]}"#.utf8)
        let value = try JSONDecoder().decode(Diarization.self, from: data)

        XCTAssertEqual(value.segments.count, 1)
        XCTAssertTrue(value.embeddings.isEmpty)
        XCTAssertTrue(value.names.isEmpty)
    }
}
