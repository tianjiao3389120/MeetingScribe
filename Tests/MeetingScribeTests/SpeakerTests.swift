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
            names: [1: " Taylor ", 2: "taylor", 3: "Taylor Chen"],
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
            VoiceProfile(name: "客户专家甲", embedding: [1, 0]),
            VoiceProfile(name: "Taylor", embedding: [0, 1]),
        ]

        let matches = VoiceProfileStore.matchReport(
            embeddings: ["2": [0.99, 0.01], "4": [0.98, 0.02]],
            qualities: [
                "2": VoiceEmbeddingQuality(
                    score: 0.9, usableDuration: 8, segmentCount: 2, cleanSegmentCount: 2),
                "4": VoiceEmbeddingQuality(
                    score: 0.9, usableDuration: 8, segmentCount: 2, cleanSegmentCount: 2)
            ],
            profiles: profiles).names

        XCTAssertEqual(matches[2], "客户专家甲")
        XCTAssertEqual(matches[4], "客户专家甲")
    }

    func testVoiceMatchingUsesAutomaticSuggestionAndUnknownTiers() {
        let profiles = [VoiceProfile(name: "Taylor", embedding: [1, 0])]
        let report = VoiceProfileStore.matchReport(
            embeddings: ["1": [0.70, 0.714], "2": [0.58, 0.815], "3": [0.50, 0.866]],
            qualities: [
                "1": VoiceEmbeddingQuality(score: 0.8, usableDuration: 10, segmentCount: 2),
                "2": VoiceEmbeddingQuality(score: 0.8, usableDuration: 10, segmentCount: 2),
                "3": VoiceEmbeddingQuality(score: 0.8, usableDuration: 10, segmentCount: 2)
            ], profiles: profiles)

        XCTAssertEqual(report.names[1], "Taylor")
        XCTAssertEqual(report.suggestions[2]?.name, "Taylor")
        XCTAssertNil(report.names[2])
        XCTAssertNil(report.names[3])
        XCTAssertNil(report.suggestions[3])
    }

    func testLowQualityVoiceprintNeverAutoMatches() {
        let report = VoiceProfileStore.matchReport(
            embeddings: ["1": [1, 0]],
            qualities: ["1": VoiceEmbeddingQuality(
                score: 0.2, usableDuration: 2, segmentCount: 1)],
            profiles: [VoiceProfile(name: "Taylor", embedding: [1, 0])])

        XCTAssertTrue(report.names.isEmpty)
        XCTAssertTrue(report.suggestions.isEmpty)
        XCTAssertTrue(report.logDescription.contains("低于"))
    }

    func testShortOrOverlappedVoiceprintRequiresManualConfirmation() {
        let profile = VoiceProfile(name: "Taylor", embedding: [1, 0])
        let short = VoiceProfileStore.matchReport(
            embeddings: ["1": [1, 0]],
            qualities: ["1": VoiceEmbeddingQuality(
                score: 0.9, usableDuration: 2.5, segmentCount: 1, cleanSegmentCount: 1)],
            profiles: [profile])
        let overlapped = VoiceProfileStore.matchReport(
            embeddings: ["1": [1, 0]],
            qualities: ["1": VoiceEmbeddingQuality(
                score: 0.9, usableDuration: 8, segmentCount: 2, cleanSegmentCount: 0)],
            profiles: [profile])

        XCTAssertTrue(short.names.isEmpty)
        XCTAssertEqual(short.suggestions[1]?.name, "Taylor")
        XCTAssertTrue(overlapped.names.isEmpty)
        XCTAssertEqual(overlapped.suggestions[1]?.name, "Taylor")
    }

    func testReferenceSegmentEnrollmentRequiresCleanFourSecondSample() {
        XCTAssertTrue(VoiceReferenceSegment(
            start: 1, end: 6, quality: 0.8, isClean: true).isEnrollmentReady)
        XCTAssertFalse(VoiceReferenceSegment(
            start: 1, end: 3, quality: 0.9, isClean: true).isEnrollmentReady)
        XCTAssertFalse(VoiceReferenceSegment(
            start: 1, end: 6, quality: 0.9, isClean: false).isEnrollmentReady)
    }

    func testEnrollmentQuarantinesWeakOrConflictingSamples() {
        XCTAssertTrue(VoiceProfileStore.shouldQuarantineEnrollment(
            targetScore: 0.3, strongestOther: 0.2, quality: 0.9))
        XCTAssertTrue(VoiceProfileStore.shouldQuarantineEnrollment(
            targetScore: 0.5, strongestOther: 0.7, quality: 0.9))
        XCTAssertTrue(VoiceProfileStore.shouldQuarantineEnrollment(
            targetScore: 0.9, strongestOther: 0.1, quality: 0.2))
        XCTAssertFalse(VoiceProfileStore.shouldQuarantineEnrollment(
            targetScore: 0.7, strongestOther: 0.5, quality: 0.9))
    }

    func testTwoConsistentConfirmedOutliersBecomeNewEnvironmentSamples() {
        var profile = VoiceProfile(name: "测试", embedding: [1, 0])
        profile.quarantineSample([0, 1], allowEnvironmentAdaptation: true)
        XCTAssertEqual(profile.pendingEnvironmentCount, 1)
        XCTAssertEqual(profile.sampleCount, 1)

        profile.quarantineSample([0.05, 0.9987], allowEnvironmentAdaptation: true)
        XCTAssertEqual(profile.pendingEnvironmentCount, 0)
        XCTAssertNil(profile.pendingEnvironmentEmbedding)
        XCTAssertEqual(profile.sampleCount, 3)
        XCTAssertEqual(profile.quarantinedSampleCount, 2)
    }

    func testConflictingOutlierNeverStartsEnvironmentAdaptation() {
        var profile = VoiceProfile(name: "测试", embedding: [1, 0])
        profile.quarantineSample([0, 1], allowEnvironmentAdaptation: false)
        XCTAssertNil(profile.pendingEnvironmentEmbedding)
        XCTAssertEqual(profile.pendingEnvironmentCount, 0)
    }

    func testConservativeClusterGroupingMergesOnlySimilarNonOverlappingVoices() {
        let value = Diarization(
            segments: [
                SpeakerSegment(start: 0, end: 2, speaker: 0),
                SpeakerSegment(start: 3, end: 5, speaker: 1),
                SpeakerSegment(start: 6, end: 8, speaker: 2)
            ],
            embeddings: ["0": [1, 0], "1": [0.99, 0.01], "2": [0, 1]])

        XCTAssertEqual(value.conservativeClusterGroups(), [[0, 1], [2]])
    }

    func testConservativeClusterGroupingDoesNotMergeOverlappingVoices() {
        let value = Diarization(
            segments: [
                SpeakerSegment(start: 0, end: 2, speaker: 0),
                SpeakerSegment(start: 1, end: 3, speaker: 1)
            ],
            embeddings: ["0": [1, 0], "1": [0.99, 0.01]])

        XCTAssertEqual(value.conservativeClusterGroups(), [[0], [1]])
    }

    func testResidualClusterGroupingMergesShortHighQualityFragment() {
        let value = Diarization(
            segments: [
                SpeakerSegment(start: 0, end: 30, speaker: 0),
                SpeakerSegment(start: 40, end: 45, speaker: 1)
            ],
            embeddings: ["0": [1, 0], "1": [0.74, 0.6726]],
            embeddingQualities: [
                "0": VoiceEmbeddingQuality(score: 0.9, usableDuration: 30, segmentCount: 3),
                "1": VoiceEmbeddingQuality(score: 0.8, usableDuration: 5, segmentCount: 1)
            ])

        XCTAssertEqual(value.conservativeClusterGroups(), [[0, 1]])
    }

    func testResidualClusterGroupingKeepsTwoLongVoicesSeparate() {
        let value = Diarization(
            segments: [
                SpeakerSegment(start: 0, end: 20, speaker: 0),
                SpeakerSegment(start: 30, end: 50, speaker: 1)
            ],
            embeddings: ["0": [1, 0], "1": [0.74, 0.6726]],
            embeddingQualities: [
                "0": VoiceEmbeddingQuality(score: 0.9, usableDuration: 20, segmentCount: 3),
                "1": VoiceEmbeddingQuality(score: 0.9, usableDuration: 20, segmentCount: 3)
            ])

        XCTAssertEqual(value.conservativeClusterGroups(), [[0], [1]])
    }

    func testFragmentationWarningFlagsManyShortClusters() {
        let segments = (0..<8).map {
            SpeakerSegment(start: Double($0 * 2), end: Double($0 * 2 + 1), speaker: $0)
        }
        XCTAssertNotNil(Diarization(segments: segments).fragmentationWarning)
    }

    func testRecognitionMetricsCountOnlyExplicitlyReviewedNames() {
        let diarization = Diarization(
            segments: [
                SpeakerSegment(start: 0, end: 1, speaker: 0),
                SpeakerSegment(start: 2, end: 3, speaker: 1),
                SpeakerSegment(start: 4, end: 5, speaker: 2)
            ],
            names: [0: "Alex", 1: "Taylor"],
            nameSuggestions: [2: VoiceMatchSuggestion(
                name: "Morgan", score: 0.58, margin: 0.07, quality: 0.8)])
        var metrics = VoiceRecognitionMetrics()
        metrics.record(
            diarization: diarization,
            confirmedNames: [0: "alex", 1: "Jordan", 2: "Morgan"])

        XCTAssertEqual(metrics.automaticPresented, 2)
        XCTAssertEqual(metrics.automaticConfirmed, 1)
        XCTAssertEqual(metrics.automaticCorrected, 1)
        XCTAssertEqual(metrics.suggestionsPresented, 1)
        XCTAssertEqual(metrics.suggestionsAccepted, 1)
        XCTAssertEqual(metrics.automaticPrecision, 0.5)
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
        XCTAssertEqual(profile.quarantinedSampleCount, 0)
        XCTAssertEqual(profile.pendingEnvironmentCount, 0)
        XCTAssertNil(profile.pendingEnvironmentEmbedding)
    }

    func testLegacyDiarizationCacheDecodesWithoutVoiceprints() throws {
        let data = Data(#"{"segments":[{"start":0,"end":2,"speaker":4}]}"#.utf8)
        let value = try JSONDecoder().decode(Diarization.self, from: data)

        XCTAssertEqual(value.segments.count, 1)
        XCTAssertTrue(value.embeddings.isEmpty)
        XCTAssertTrue(value.names.isEmpty)
        XCTAssertTrue(value.embeddingQualities.isEmpty)
        XCTAssertTrue(value.referenceSegments.isEmpty)
        XCTAssertTrue(value.nameSuggestions.isEmpty)
    }
}
