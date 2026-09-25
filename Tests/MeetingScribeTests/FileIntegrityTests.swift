import XCTest
@testable import MeetingScribe

final class FileIntegrityTests: XCTestCase {
    func testSHA256MatchesKnownValue() throws {
        let url = temporaryRoot().appendingPathComponent("value.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: url)

        XCTAssertEqual(try FileIntegrity.sha256(of: url),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(FileIntegrity.matchesSHA256(
            "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD",
            at: url))
    }

    func testArchivePathsRejectTraversalAndAbsoluteLocations() throws {
        XCTAssertNoThrow(try FileIntegrity.validateArchiveEntryPaths([
            "MeetingScribe识别模型/manifest.json",
            "MeetingScribe识别模型/speaker/model.onnx"
        ]))
        XCTAssertThrowsError(try FileIntegrity.validateArchiveEntryPaths(["../outside"]))
        XCTAssertThrowsError(try FileIntegrity.validateArchiveEntryPaths(["/tmp/outside"]))
        XCTAssertThrowsError(try FileIntegrity.validateArchiveEntryPaths(["C:\\outside"]))
    }

    func testSymbolicLinksAreRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target")
        try Data("model".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: target)

        XCTAssertThrowsError(try FileIntegrity.rejectSymbolicLinks(in: root))
    }

    func testPinnedModelMetadataIsComplete() {
        XCTAssertFalse(ToolLocator.transcriptionModelURL.contains("/resolve/main/"))
        XCTAssertFalse(ToolLocator.vadModelURL.contains("/resolve/main/"))
        XCTAssertEqual(ToolLocator.transcriptionModelSHA256.count, 64)
        XCTAssertEqual(ToolLocator.vadModelSHA256.count, 64)
        XCTAssertEqual(Diarizer.segmentationArchiveSHA256.count, 64)
        XCTAssertEqual(Diarizer.embeddingModelSHA256.count, 64)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("file-integrity-tests-\(UUID().uuidString)")
    }
}
