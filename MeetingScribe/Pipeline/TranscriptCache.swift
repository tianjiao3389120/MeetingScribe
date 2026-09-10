import Foundation
import CryptoKit

/// Caches transcripts on disk so re-running a file is seconds, not minutes.
///
/// Transcription dominates the pipeline (~3 minutes for a 40-minute meeting),
/// and re-running the same recording is the common case: tweaking the prompt,
/// switching provider, retrying after a failure. The model call is cheap by
/// comparison and always re-run, since that's usually the reason for the retry.
enum TranscriptCache {

    static let transcriptionVersion = "transcript-v2|large-v3-turbo|vad-silero-5.1.2|vmsd12|vsd220|mc-1|srt1"
    static let diarizationVersion = "diarization-v3|pyannote-int8|campplus|threshold0.8|min0.5-0.6|embeddings1"

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Identifies a recording plus the settings that shaped its transcript.
    ///
    /// Hashing gigabytes would cost more than it saves, so the file is
    /// identified by size, modification time and a sample of its bytes — enough
    /// to notice a different or re-encoded file without reading all of it.
    static func key(for url: URL, language: String, glossary: String,
                    version: String = transcriptionVersion) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        var hasher = SHA256()
        hasher.update(data: Data("\(size)|\(modified)".utf8))

        // Head and tail: a re-encode or a different recording changes both.
        let sample = 256 * 1024
        if let head = try? handle.read(upToCount: sample) { hasher.update(data: head) }
        if size > Int64(sample * 2) {
            try? handle.seek(toOffset: UInt64(size) - UInt64(sample))
            if let tail = try? handle.read(upToCount: sample) { hasher.update(data: tail) }
        }

        // Transcription settings are part of the identity — changing the
        // glossary must produce a fresh transcript, not a stale hit.
        hasher.update(data: Data("|\(language)|\(Transcriber.trimGlossary(glossary))|\(version)".utf8))

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func load(key: String) -> Transcript? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data),
              !transcript.segments.isEmpty else { return nil }

        // Touch so least-recently-used pruning keeps what's in active use.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return transcript
    }

    static func save(_ transcript: Transcript, key: String) {
        guard !transcript.segments.isEmpty,
              let data = try? JSONEncoder().encode(transcript) else { return }
        try? data.write(to: directory.appendingPathComponent("\(key).json"))
        prune()
    }

    static func metadata(key: String) -> (path: String, createdAt: Date?, bytes: Int64)? {
        let url = directory.appendingPathComponent("\(key).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (url.path, attributes?[.creationDate] as? Date,
                (attributes?[.size] as? NSNumber)?.int64Value ?? 0)
    }

    // MARK: - Housekeeping

    /// Transcripts are small (tens of KB), so a generous cap is still trivial
    /// on disk while covering months of ordinary use.
    private static let maxEntries = 200

    private static func prune() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
            entries.count > maxEntries else { return }

        let sorted = entries.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }
        for url in sorted.prefix(entries.count - maxEntries) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func clear() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for url in entries { try? FileManager.default.removeItem(at: url) }
    }

    static var summary: (count: Int, bytes: Int64) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
        let bytes = entries.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (entries.count, bytes)
    }
}

/// Same storage strategy as `TranscriptCache`, for speaker timelines.
/// Diarization costs about as much as transcription, so re-running a file with
/// speaker separation on must not pay for it twice.
enum DiarizationCache {

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/speakers", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func load(key: String) -> Diarization? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Diarization.self, from: data),
              !value.segments.isEmpty,
              // Pre-voiceprint caches cannot support naming. Treat them as a
              // miss so the next run extracts embeddings once.
              !value.embeddings.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return value
    }

    static func save(_ value: Diarization, key: String) {
        guard !value.segments.isEmpty,
              let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent("\(key).json"))
    }

    static func metadata(key: String) -> (path: String, createdAt: Date?, bytes: Int64)? {
        let url = directory.appendingPathComponent("\(key).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (url.path, attributes?[.creationDate] as? Date,
                (attributes?[.size] as? NSNumber)?.int64Value ?? 0)
    }

    static func clear() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for url in entries { try? FileManager.default.removeItem(at: url) }
    }

    static var count: Int {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).count) ?? 0
    }

    static var bytes: Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return entries.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}
