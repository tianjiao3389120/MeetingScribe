import XCTest
@testable import MeetingScribe

final class LibraryBackupTests: XCTestCase {
    func testBackupPackageRestoresByMergingWithoutOverwrite() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-backup-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = LibraryBackup.Paths(root: temporary.appendingPathComponent("source"))
        let destination = LibraryBackup.Paths(root: temporary.appendingPathComponent("destination"))
        let package = temporary.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let meeting = MeetingRecord(
            title: "客户双周会", sourcePath: "/meeting.mov", duration: 10,
            backend: "测试", model: "mock", summaryMarkdown: "纪要",
            structuredSummary: nil, transcript: Transcript(segments: []),
            speakerNames: [:], usedSummaryFallback: false)
        let materialURL = temporary.appendingPathComponent("brief.md")
        try "项目材料".write(to: materialURL, atomically: true, encoding: .utf8)
        let material = SupportingMaterial(sourceURL: materialURL, kind: .text,
                                          extractedText: "项目材料")
        try MeetingHistoryStore.save(meeting, root: source.meetings, materialSources: [material])
        let workspace = MeetingWorkspace(name: "客户项目", kind: .customer)
        try MeetingWorkspaceStore.save([workspace], to: source.workspaces)
        try FileManager.default.createDirectory(at: source.feedback, withIntermediateDirectories: true)
        try Data("feedback".utf8).write(to: source.feedback.appendingPathComponent("feedback.json"))
        try FileManager.default.createDirectory(at: source.realtime, withIntermediateDirectories: true)
        try Data("subtitle".utf8).write(to: source.realtime.appendingPathComponent("session.txt"))
        let profile = VoiceProfile(name: "测试用户", embedding: [1, 0, 0])
        try JSONEncoder().encode([profile]).write(to: source.voiceProfiles)

        try LibraryBackup.createPackage(at: package, source: source)
        let first = try LibraryBackup.restorePackage(from: package, destination: destination)
        XCTAssertEqual(first.meetingsAdded, 1)
        XCTAssertEqual(first.workspacesAdded, 1)
        XCTAssertEqual(first.filesAdded, 3)
        XCTAssertEqual(try MeetingHistoryStore.loadAll(root: destination.meetings).first?.title,
                       "客户双周会")
        let restoredMaterial = try XCTUnwrap(
            MeetingHistoryStore.loadAll(root: destination.meetings).first?.materials?.first)
        let restoredPath = URL(fileURLWithPath: restoredMaterial.sourcePath)
            .resolvingSymlinksInPath().path
        let destinationPath = destination.meetings.resolvingSymlinksInPath().path
        XCTAssertTrue(restoredPath.hasPrefix(destinationPath))
        XCTAssertEqual(try String(contentsOfFile: restoredMaterial.sourcePath, encoding: .utf8), "项目材料")
        XCTAssertEqual(try MeetingWorkspaceStore.load(from: destination.workspaces).first?.id,
                       workspace.id)

        let second = try LibraryBackup.restorePackage(from: package, destination: destination)
        XCTAssertEqual(second.meetingsAdded, 0)
        XCTAssertEqual(second.workspacesAdded, 0)
        XCTAssertEqual(second.filesAdded, 0)
        XCTAssertEqual(second.skipped, 5)
    }

    func testBackupRejectsMissingOrFutureManifest() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-invalid-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let destination = LibraryBackup.Paths(root: temporary.appendingPathComponent("destination"))
        XCTAssertThrowsError(try LibraryBackup.restorePackage(from: temporary,
                                                               destination: destination))

        let manifest = LibraryBackup.Manifest(
            formatVersion: LibraryBackup.formatVersion + 1, createdAt: Date(),
            appName: "MeetingScribe", meetingCount: 0)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: temporary.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try LibraryBackup.restorePackage(from: temporary,
                                                               destination: destination))
    }

    func testZipArchiveRoundTrip() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-zip-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = LibraryBackup.Paths(root: temporary.appendingPathComponent("source"))
        let destination = LibraryBackup.Paths(root: temporary.appendingPathComponent("destination"))
        let archive = temporary.appendingPathComponent("backup.zip")
        let customer = MeetingWorkspace(name: "恢复客户", kind: .customer)
        let project = MeetingWorkspace(
            name: "恢复测试", kind: .project, customerID: customer.id,
            meetingTypes: ["双周会"])
        try MeetingWorkspaceStore.save([customer, project], to: source.workspaces)

        try LibraryBackup.createArchive(at: archive, source: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let result = try LibraryBackup.restoreArchive(from: archive, destination: destination)
        XCTAssertEqual(result.workspacesAdded, 2)
        let restored = try MeetingWorkspaceStore.load(from: destination.workspaces)
        XCTAssertEqual(Set(restored.map(\.name)), Set(["恢复客户", "恢复测试"]))
        XCTAssertEqual(restored.first(where: { $0.id == project.id })?.customerID, customer.id)
        XCTAssertEqual(restored.first(where: { $0.id == project.id })?.configuredMeetingTypes,
                       ["双周会"])
    }
}
