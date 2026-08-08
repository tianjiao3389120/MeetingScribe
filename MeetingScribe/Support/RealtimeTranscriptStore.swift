import Foundation

struct RealtimeTranscriptRecord: Identifiable, Hashable {
    let originalURL: URL
    let translatedURL: URL?
    let audioURL: URL?
    let createdAt: Date
    let customTitle: String?
    let searchableText: String

    var id: String { originalURL.path }
    var title: String {
        let value = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? createdAt.formatted(date: .abbreviated, time: .shortened) : value
    }
}

enum RealtimeTranscriptStore {
    private struct Metadata: Codable { var title: String }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/realtime", isDirectory: true)
    }

    static func load() -> [RealtimeTranscriptRecord] {
        load(in: directory)
    }

    static func load(in directory: URL) -> [RealtimeTranscriptRecord] {
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path)
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return files.filter {
            $0.pathExtension.lowercased() == "txt" && !$0.lastPathComponent.hasSuffix(".translated.txt")
        }.map { original in
            let base = original.deletingPathExtension()
            let translated = base.appendingPathExtension("translated.txt")
            let audio = base.appendingPathExtension("wav")
            let metadata = base.appendingPathExtension("meta.json")
            [original, translated, audio, metadata].forEach(secureFile)
            let values = try? original.resourceValues(forKeys: [.contentModificationDateKey])
            let originalText = (try? String(contentsOf: original, encoding: .utf8)) ?? ""
            let translatedText = (try? String(contentsOf: translated, encoding: .utf8)) ?? ""
            let title = (try? Data(contentsOf: metadata))
                .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0).title }
            return RealtimeTranscriptRecord(
                originalURL: original,
                translatedURL: FileManager.default.fileExists(atPath: translated.path) ? translated : nil,
                audioURL: FileManager.default.fileExists(atPath: audio.path) ? audio : nil,
                createdAt: values?.contentModificationDate ?? .distantPast,
                customTitle: title,
                searchableText: originalText + "\n" + translatedText)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func prepareDirectory(_ directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func secureFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func rename(_ record: RealtimeTranscriptRecord, to rawTitle: String) throws {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = record.originalURL.deletingPathExtension().appendingPathExtension("meta.json")
        if title.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try prepareDirectory(record.originalURL.deletingLastPathComponent())
        try JSONEncoder().encode(Metadata(title: title)).write(to: url, options: .atomic)
        secureFile(url)
    }

    static func remove(_ record: RealtimeTranscriptRecord) throws {
        let base = record.originalURL.deletingPathExtension()
        for url in [record.originalURL,
                    base.appendingPathExtension("translated.txt"),
                    base.appendingPathExtension("wav"),
                    base.appendingPathExtension("meta.json")]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func removeAll(in directory: URL = directory) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    static func export(_ record: RealtimeTranscriptRecord, to directory: URL) throws {
        let name = safeFilename(record.title)
        try FileManager.default.copyItem(at: record.originalURL,
            to: availableURL(in: directory, name: "\(name) 原文", extension: "txt"))
        if let translatedURL = record.translatedURL {
            try FileManager.default.copyItem(at: translatedURL,
                to: availableURL(in: directory, name: "\(name) 翻译", extension: "txt"))
        }
        if let audioURL = record.audioURL {
            try FileManager.default.copyItem(at: audioURL,
                to: availableURL(in: directory, name: "\(name) 音频", extension: "wav"))
        }
    }

    static func summary(in directory: URL = directory) -> (count: Int, bytes: Int64) {
        let records = load(in: directory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return (records.count, 0)
        }
        var bytes: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0) }
        }
        return (records.count, bytes)
    }

    private static func safeFilename(_ value: String) -> String {
        let safe = value.replacingOccurrences(of: #"[/\\:]"#, with: "_", options: .regularExpression)
        return safe.isEmpty ? "实时字幕" : safe
    }

    private static func availableURL(in directory: URL, name: String, extension ext: String) -> URL {
        var candidate = directory.appendingPathComponent(name).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }
}
