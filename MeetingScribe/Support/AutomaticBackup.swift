import Foundation

enum AutomaticBackupFrequency: String, CaseIterable, Identifiable {
    case daily, weekly

    var id: String { rawValue }
    var label: String { self == .daily ? "每天" : "每周" }
    var interval: TimeInterval { self == .daily ? 24 * 60 * 60 : 7 * 24 * 60 * 60 }
}

struct AutomaticBackupConfiguration: Sendable {
    var enabled: Bool
    var directoryPath: String
    var frequency: AutomaticBackupFrequency
    var retentionCount: Int

    static func load(defaults: UserDefaults = .standard) -> AutomaticBackupConfiguration {
        AutomaticBackupConfiguration(
            enabled: defaults.bool(forKey: Keys.enabled),
            directoryPath: defaults.string(forKey: Keys.directory) ?? "",
            frequency: AutomaticBackupFrequency(
                rawValue: defaults.string(forKey: Keys.frequency) ?? "") ?? .daily,
            retentionCount: max(1, defaults.object(forKey: Keys.retention) as? Int ?? 7))
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(directoryPath, forKey: Keys.directory)
        defaults.set(frequency.rawValue, forKey: Keys.frequency)
        defaults.set(retentionCount, forKey: Keys.retention)
    }

    private enum Keys {
        static let enabled = "automaticBackup.enabled"
        static let directory = "automaticBackup.directory"
        static let frequency = "automaticBackup.frequency"
        static let retention = "automaticBackup.retention"
    }
}

@MainActor
enum AutomaticBackupManager {
    private static let lastSuccessKey = "automaticBackup.lastSuccess"
    private static let lastMessageKey = "automaticBackup.lastMessage"
    private(set) static var isRunning = false

    static var lastSuccess: Date? {
        UserDefaults.standard.object(forKey: lastSuccessKey) as? Date
    }

    static var lastMessage: String? {
        UserDefaults.standard.string(forKey: lastMessageKey)
    }

    @discardableResult
    static func runIfNeeded(force: Bool = false, now: Date = Date()) async -> String? {
        guard !isRunning else { return nil }
        let configuration = AutomaticBackupConfiguration.load()
        guard !configuration.directoryPath.isEmpty, force || configuration.enabled else { return nil }
        if !force, let lastSuccess,
           now.timeIntervalSince(lastSuccess) < configuration.frequency.interval { return nil }

        isRunning = true
        defer { isRunning = false }
        do {
            let result = try await Task.detached {
                try createBackup(configuration: configuration, now: now)
            }.value
            UserDefaults.standard.set(now, forKey: lastSuccessKey)
            UserDefaults.standard.set(result, forKey: lastMessageKey)
            return result
        } catch {
            let message = "自动备份失败：\(error.localizedDescription)"
            UserDefaults.standard.set(message, forKey: lastMessageKey)
            return message
        }
    }

    nonisolated static func createBackup(configuration: AutomaticBackupConfiguration,
                                          now: Date = Date()) throws -> String {
        let manager = FileManager.default
        let directory = URL(fileURLWithPath: configuration.directoryPath, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let filename = "MeetingScribe 自动备份 \(formatter.string(from: now)).zip"
        let finalURL = directory.appendingPathComponent(filename)
        let partialURL = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: partialURL) }
        try LibraryBackup.createArchive(at: partialURL)
        try manager.moveItem(at: partialURL, to: finalURL)
        try pruneBackups(in: directory, keeping: configuration.retentionCount)
        return "自动备份成功：\(filename)"
    }

    nonisolated static func pruneBackups(in directory: URL, keeping count: Int) throws {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix("MeetingScribe 自动备份 ")
                && $0.pathExtension.lowercased() == "zip" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                return left > right
            }
        for file in files.dropFirst(max(1, count)) { try manager.removeItem(at: file) }
    }
}
