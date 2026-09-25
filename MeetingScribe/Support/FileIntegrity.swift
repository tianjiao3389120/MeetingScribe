import CryptoKit
import Foundation

enum FileIntegrity {
    enum Failure: Error { case unsafeArchive }

    private struct Verification {
        let bytes: Int64
        let modifiedAt: TimeInterval
        let expected: String
        let matches: Bool
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var verificationCache: [String: Verification] = [:]

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matchesSHA256(_ expected: String, at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return false }
        let normalizedExpected = expected.lowercased()
        let key = url.standardizedFileURL.path
        if let cached = cacheLock.withLock({ verificationCache[key] }),
           cached.bytes == bytes, cached.modifiedAt == modified.timeIntervalSince1970,
           cached.expected == normalizedExpected {
            return cached.matches
        }
        let matches = (try? sha256(of: url)) == normalizedExpected
        cacheLock.withLock {
            verificationCache[key] = Verification(
                bytes: bytes, modifiedAt: modified.timeIntervalSince1970,
                expected: normalizedExpected, matches: matches)
        }
        return matches
    }

    static func rejectSymbolicLinks(in root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw CocoaError(.fileReadInvalidFileName)
            }
        }
    }

    static func validateArchiveEntryPaths(_ entries: [String]) throws {
        guard !entries.isEmpty else { throw Failure.unsafeArchive }
        for entry in entries {
            let normalized = entry.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            guard !normalized.hasPrefix("/"), !normalized.hasPrefix("~"),
                  !components.contains(".."),
                  components.first?.contains(":") != true else {
                throw Failure.unsafeArchive
            }
        }
    }

    static func validateZipEntries(in archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        let output = Pipe(); process.standardOutput = output
        process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? output.fileHandleForReading.readToEnd(),
              let listing = String(data: data, encoding: .utf8) else {
            throw Failure.unsafeArchive
        }
        try validateArchiveEntryPaths(
            listing.split(whereSeparator: { $0.isNewline }).map(String.init))
    }
}
