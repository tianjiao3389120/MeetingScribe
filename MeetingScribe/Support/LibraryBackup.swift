import Foundation

enum LibraryBackup {
    static let formatVersion = 1

    struct Manifest: Codable {
        let formatVersion: Int
        let createdAt: Date
        let appName: String
        let meetingCount: Int
    }

    struct RestoreResult {
        let meetingsAdded: Int
        let workspacesAdded: Int
        let filesAdded: Int
        let skipped: Int

        var message: String {
            "已恢复 \(meetingsAdded) 场会议、\(workspacesAdded) 个会议空间和 \(filesAdded) 个附加文件；跳过 \(skipped) 个已有项目。"
        }
    }

    struct Paths {
        let root: URL
        var meetings: URL { root.appendingPathComponent("Meetings", isDirectory: true) }
        var workspaces: URL { root.appendingPathComponent("workspaces.json") }
        var feedback: URL { root.appendingPathComponent("Feedback", isDirectory: true) }
        var realtime: URL { root.appendingPathComponent("realtime", isDirectory: true) }
        var voiceProfiles: URL { root.appendingPathComponent("voice-profiles.json") }
        var voiceProfileClips: URL { root.appendingPathComponent("voice-profile-clips", isDirectory: true) }
        var projectLedger: URL { root.appendingPathComponent("project-ledger.json") }

        static var live: Paths { Paths(root: Diarizer.supportDirectory) }
    }

    enum Failure: LocalizedError {
        case command(String)
        case invalidBackup
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .command(let detail): return "备份工具执行失败：\(detail)"
            case .invalidBackup: return "所选文件不是有效的 MeetingScribe 备份。"
            case .unsupportedVersion(let version): return "备份格式版本 \(version) 暂不支持。"
            }
        }
    }

    static func createArchive(at destination: URL, source: Paths = .live) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let package = temporary.appendingPathComponent("MeetingScribe Backup", isDirectory: true)
        try createPackage(at: package, source: source)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", package.path, destination.path])
    }

    static func restoreArchive(from archive: URL, destination: Paths = .live) throws -> RestoreResult {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try runDitto(["-x", "-k", archive.path, temporary.path])
        try rejectSymbolicLinks(in: temporary)
        let package = temporary.appendingPathComponent("MeetingScribe Backup", isDirectory: true)
        return try restorePackage(from: package, destination: destination)
    }

    static func createPackage(at package: URL, source: Paths) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        for (from, name) in [(source.meetings, "Meetings"),
                             (source.feedback, "Feedback"),
                             (source.realtime, "realtime"),
                             (source.voiceProfileClips, "voice-profile-clips")] where manager.fileExists(atPath: from.path) {
            try manager.copyItem(at: from, to: package.appendingPathComponent(name, isDirectory: true))
        }
        for (from, name) in [(source.workspaces, "workspaces.json"),
                             (source.voiceProfiles, "voice-profiles.json"),
                             (source.projectLedger, "project-ledger.json")]
        where manager.fileExists(atPath: from.path) {
            try manager.copyItem(at: from, to: package.appendingPathComponent(name))
        }
        let count = (try? MeetingHistoryStore.loadAll(root: source.meetings).count) ?? 0
        let manifest = Manifest(formatVersion: formatVersion, createdAt: Date(),
                                appName: "MeetingScribe", meetingCount: count)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: package.appendingPathComponent("manifest.json"), options: .atomic)
    }

    static func restorePackage(from package: URL, destination: Paths) throws -> RestoreResult {
        let manifestURL = package.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw Failure.invalidBackup }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data),
              manifest.appName == "MeetingScribe" else { throw Failure.invalidBackup }
        guard manifest.formatVersion <= formatVersion else {
            throw Failure.unsupportedVersion(manifest.formatVersion)
        }

        let manager = FileManager.default
        try manager.createDirectory(at: destination.root, withIntermediateDirectories: true)
        var meetingsAdded = 0, workspacesAdded = 0, filesAdded = 0, skipped = 0

        let backupMeetings = package.appendingPathComponent("Meetings", isDirectory: true)
        if manager.fileExists(atPath: backupMeetings.path) {
            try manager.createDirectory(at: destination.meetings, withIntermediateDirectories: true)
            for source in try manager.contentsOfDirectory(at: backupMeetings,
                                                          includingPropertiesForKeys: [.isDirectoryKey]) {
                let metadata = source.appendingPathComponent("metadata.json")
                guard manager.fileExists(atPath: metadata.path) else { throw Failure.invalidBackup }
                let target = destination.meetings.appendingPathComponent(source.lastPathComponent)
                if manager.fileExists(atPath: target.path) { skipped += 1; continue }
                try manager.copyItem(at: source, to: target)
                try rewriteMaterialPaths(in: target, historyRoot: destination.meetings)
                meetingsAdded += 1
            }
        }

        let backupWorkspaces = package.appendingPathComponent("workspaces.json")
        if manager.fileExists(atPath: backupWorkspaces.path) {
            let incoming = try MeetingWorkspaceStore.load(from: backupWorkspaces)
            var existing = try MeetingWorkspaceStore.load(from: destination.workspaces)
            let ids = Set(existing.map(\.id))
            let additions = incoming.filter { !ids.contains($0.id) }
            workspacesAdded = additions.count; skipped += incoming.count - additions.count
            existing.append(contentsOf: additions)
            try MeetingWorkspaceStore.save(existing, to: destination.workspaces)
        }

        for name in ["Feedback", "realtime", "voice-profile-clips"] {
            let source = package.appendingPathComponent(name, isDirectory: true)
            let target = destination.root.appendingPathComponent(name, isDirectory: true)
            let result = try mergeFiles(from: source, to: target)
            filesAdded += result.added; skipped += result.skipped
        }
        let voiceSource = package.appendingPathComponent("voice-profiles.json")
        if manager.fileExists(atPath: voiceSource.path) {
            let incoming = try JSONDecoder().decode([VoiceProfile].self, from: Data(contentsOf: voiceSource))
            let existing = manager.fileExists(atPath: destination.voiceProfiles.path)
                ? try JSONDecoder().decode([VoiceProfile].self,
                                           from: Data(contentsOf: destination.voiceProfiles)) : []
            let ids = Set(existing.map(\.id))
            let names = Set(existing.map { $0.name.lowercased() })
            let additions = incoming.filter { !ids.contains($0.id) && !names.contains($0.name.lowercased()) }
            skipped += incoming.count - additions.count
            if !additions.isEmpty {
                let data = try JSONEncoder().encode(existing + additions)
                try data.write(to: destination.voiceProfiles, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: destination.voiceProfiles.path)
                filesAdded += additions.count
            }
        }
        let ledgerSource = package.appendingPathComponent("project-ledger.json")
        if manager.fileExists(atPath: ledgerSource.path) {
            let incoming = try ProjectLedgerStore.load(from: ledgerSource)
            var existing = try ProjectLedgerStore.load(from: destination.projectLedger)
            let actionIDs = Set(existing.actions.map(\.id))
            let proposalIDs = Set(existing.proposals.map(\.id))
            let newActions = incoming.actions.filter { !actionIDs.contains($0.id) }
            let newProposals = incoming.proposals.filter { !proposalIDs.contains($0.id) }
            existing.actions.append(contentsOf: newActions)
            existing.proposals.append(contentsOf: newProposals)
            try ProjectLedgerStore.save(existing, to: destination.projectLedger)
            filesAdded += newActions.count + newProposals.count
            skipped += incoming.actions.count - newActions.count
                + incoming.proposals.count - newProposals.count
        }
        return RestoreResult(meetingsAdded: meetingsAdded, workspacesAdded: workspacesAdded,
                             filesAdded: filesAdded, skipped: skipped)
    }

    private static func mergeFiles(from source: URL, to target: URL) throws -> (added: Int, skipped: Int) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return (0, 0) }
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        var added = 0, skipped = 0
        for file in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let destination = target.appendingPathComponent(file.lastPathComponent)
            if manager.fileExists(atPath: destination.path) { skipped += 1; continue }
            try manager.copyItem(at: file, to: destination); added += 1
        }
        return (added, skipped)
    }

    private static func rewriteMaterialPaths(in meetingDirectory: URL, historyRoot: URL) throws {
        let metadata = meetingDirectory.appendingPathComponent("metadata.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: metadata))
        guard let references = record.materials, !references.isEmpty else { return }
        let materialsDirectory = meetingDirectory.appendingPathComponent("materials", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: materialsDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count == references.count else { throw Failure.invalidBackup }
        record.materials = zip(references, files).map { reference, file in
            MaterialReference(name: reference.name, kind: reference.kind, sourcePath: file.path)
        }
        try MeetingHistoryStore.save(record, root: historyRoot)
    }

    private static func rejectSymbolicLinks(in root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw Failure.invalidBackup
            }
        }
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.command(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
