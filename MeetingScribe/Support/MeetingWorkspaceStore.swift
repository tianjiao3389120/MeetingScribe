import Foundation

enum MeetingWorkspaceStore {
    static let fileURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingScribe/workspaces.json")

    static func load(from url: URL = fileURL) throws -> [MeetingWorkspace] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([MeetingWorkspace].self, from: Data(contentsOf: url))
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    static func save(_ values: [MeetingWorkspace], to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(values).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }
}
