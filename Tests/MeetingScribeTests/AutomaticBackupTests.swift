import XCTest
@testable import MeetingScribe

final class AutomaticBackupTests: XCTestCase {
    func testAutomaticBackupConfigurationRoundTripAndDefaults() throws {
        let name = "MeetingScribeTests.AutomaticBackup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let initial = AutomaticBackupConfiguration.load(defaults: defaults)
        XCTAssertFalse(initial.enabled)
        XCTAssertEqual(initial.frequency, .daily)
        XCTAssertEqual(initial.retentionCount, 7)

        let expected = AutomaticBackupConfiguration(
            enabled: true, directoryPath: "/tmp/iCloud",
            frequency: .weekly, retentionCount: 12)
        expected.save(defaults: defaults)
        let restored = AutomaticBackupConfiguration.load(defaults: defaults)
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.directoryPath, "/tmp/iCloud")
        XCTAssertEqual(restored.frequency, .weekly)
        XCTAssertEqual(restored.retentionCount, 12)
    }

    func testPruneKeepsNewestAutomaticBackupsOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<4 {
            let file = directory.appendingPathComponent("MeetingScribe 自动备份 2026-08-0\(index + 1).zip")
            try Data().write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: file.path)
        }
        let manual = directory.appendingPathComponent("我的手工备份.zip")
        try Data().write(to: manual)

        try AutomaticBackupManager.pruneBackups(in: directory, keeping: 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("MeetingScribe 自动备份 ") }.count, 2)
        XCTAssertTrue(names.contains(manual.lastPathComponent))
        XCTAssertTrue(names.contains("MeetingScribe 自动备份 2026-08-04.zip"))
        XCTAssertTrue(names.contains("MeetingScribe 自动备份 2026-08-03.zip"))
    }
}
