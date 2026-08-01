import Foundation

enum MeetingHistoryStore {
    static let defaultDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/Meetings", isDirectory: true)
    }()

    static func save(_ record: MeetingRecord, root: URL = defaultDirectory) throws {
        let directory = root.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try secureWrite(encoder.encode(record),
                        to: directory.appendingPathComponent("metadata.json"))
        try secureWrite(Data(record.summaryMarkdown.utf8),
                        to: directory.appendingPathComponent("minutes.md"))
        try secureWrite(encoder.encode(record.transcript),
                        to: directory.appendingPathComponent("transcript.json"))
        if let structured = record.structuredSummary {
            try secureWrite(encoder.encode(structured),
                            to: directory.appendingPathComponent("minutes.json"))
        }
    }

    static func loadAll(root: URL = defaultDirectory) throws -> [MeetingRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return directories.compactMap { directory in
            let url = directory.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(MeetingRecord.self, from: data),
                  record.schemaVersion <= MeetingRecord.currentSchemaVersion else { return nil }
            return record
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func remove(id: UUID, root: URL = defaultDirectory) throws {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    static func export(_ record: MeetingRecord, to directory: URL) throws {
        let base = record.title
        try record.summaryMarkdown.write(
            to: directory.appendingPathComponent("\(base) 纪要.md"),
            atomically: true, encoding: .utf8)
        try record.transcript.timecodedText.write(
            to: directory.appendingPathComponent("\(base) 逐字稿.txt"),
            atomically: true, encoding: .utf8)
        if let structured = record.structuredSummary {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(structured).write(
                to: directory.appendingPathComponent("\(base) 纪要.json"), options: .atomic)
        }
    }

    private static func secureWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }
}
