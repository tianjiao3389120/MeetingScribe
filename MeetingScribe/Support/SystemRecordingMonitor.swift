import Foundation
import Observation

/// Watches the folder used by macOS Screenshot after launching its recording UI.
/// A recording is offered only after its size is stable across two polls, so an
/// in-progress MOV can never be handed to AVFoundation.
@Observable
@MainActor
final class SystemRecordingMonitor {
    private(set) var isWatching = false
    private(set) var detectedURL: URL?
    private(set) var folder: URL = SystemRecordingMonitor.captureFolder()

    private var startedAt = Date.distantFuture
    private var timer: Timer?
    private var previousSizes: [URL: Int64] = [:]

    func begin() {
        stop()
        folder = Self.captureFolder()
        startedAt = Date().addingTimeInterval(-1)
        detectedURL = nil
        previousSizes = [:]
        isWatching = true
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isWatching = false
        previousSizes = [:]
    }

    func consume() -> URL? {
        let result = detectedURL
        detectedURL = nil
        return result
    }

    private func poll() {
        guard isWatching else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey,
                                         .contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return }

        let candidates = files.compactMap { url -> (URL, Date, Int64)? in
            guard ["mov", "mp4"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            let date = values.creationDate ?? values.contentModificationDate ?? .distantPast
            guard date >= startedAt else { return nil }
            return (url, date, Int64(values.fileSize ?? 0))
        }.sorted { $0.1 > $1.1 }

        var current: [URL: Int64] = [:]
        for (url, _, size) in candidates {
            current[url] = size
            if size > 0, previousSizes[url] == size {
                detectedURL = url
                stop()
                return
            }
        }
        previousSizes = current
    }

    static func captureFolder() -> URL {
        let stored = UserDefaults.standard.persistentDomain(forName: "com.apple.screencapture")?["location"]
            as? String
        if let stored, !stored.isEmpty {
            let expanded = NSString(string: stored).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
}
