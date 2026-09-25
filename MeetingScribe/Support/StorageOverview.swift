import Foundation

struct StorageOverview {
    let meetingCount: Int
    let historyBytes: Int64
    let cacheCount: Int
    let cacheBytes: Int64
    let debugRunCount: Int
    let debugBytes: Int64
    let speakerRuntimeBytes: Int64
    let missingSourceCount: Int

    static func load(historyRoot: URL = MeetingHistoryStore.defaultDirectory) -> StorageOverview {
        let records = (try? MeetingHistoryStore.loadAll(root: historyRoot)) ?? []
        let transcript = TranscriptCache.summary
        let debugDirectory = AppEnvironment.supportDirectory
            .appendingPathComponent("Debug", isDirectory: true)
        let debugRuns = ((try? FileManager.default.contentsOfDirectory(
            at: debugDirectory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []).filter {
                $0.lastPathComponent.hasPrefix("run-")
                    && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            }.count
        return StorageOverview(
            meetingCount: records.count,
            historyBytes: directorySize(historyRoot),
            cacheCount: transcript.count + DiarizationCache.count,
            cacheBytes: transcript.bytes + DiarizationCache.bytes,
            debugRunCount: debugRuns,
            debugBytes: directorySize(debugDirectory),
            speakerRuntimeBytes: Diarizer.installedSize,
            missingSourceCount: records.filter {
                !FileManager.default.fileExists(atPath: $0.sourcePath)
            }.count)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey,
                                                   .fileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
