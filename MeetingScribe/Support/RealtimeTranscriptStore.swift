import Foundation

struct RealtimeTranscriptRecord: Identifiable, Hashable {
    let originalURL: URL
    let translatedURL: URL?
    let audioURL: URL?
    let createdAt: Date

    var id: String { originalURL.path }
    var title: String { createdAt.formatted(date: .abbreviated, time: .shortened) }
}

enum RealtimeTranscriptStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/realtime", isDirectory: true)
    }

    static func load() -> [RealtimeTranscriptRecord] {
        load(in: directory)
    }

    static func load(in directory: URL) -> [RealtimeTranscriptRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return files.filter {
            $0.pathExtension.lowercased() == "txt" && !$0.lastPathComponent.hasSuffix(".translated.txt")
        }.map { original in
            let base = original.deletingPathExtension()
            let translated = base.appendingPathExtension("translated.txt")
            let audio = base.appendingPathExtension("wav")
            let values = try? original.resourceValues(forKeys: [.contentModificationDateKey])
            return RealtimeTranscriptRecord(
                originalURL: original,
                translatedURL: FileManager.default.fileExists(atPath: translated.path) ? translated : nil,
                audioURL: FileManager.default.fileExists(atPath: audio.path) ? audio : nil,
                createdAt: values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.createdAt > $1.createdAt }
    }
}
