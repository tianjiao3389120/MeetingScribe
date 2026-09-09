import Foundation

/// Learns whole-pipeline speed on this Mac. Samples are deliberately local and bounded.
enum ProcessingTimeHistory {
    private struct Sample: Codable {
        let mediaDuration: TimeInterval
        let processingDuration: TimeInterval
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/processing-times.json")
    }

    static func record(mediaDuration: TimeInterval, processingDuration: TimeInterval) {
        guard mediaDuration > 0, processingDuration > 0 else { return }
        var samples = load()
        samples.append(Sample(mediaDuration: mediaDuration, processingDuration: processingDuration))
        samples = Array(samples.suffix(20))
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(samples).write(to: url, options: .atomic)
        } catch { /* Timing history must never fail a meeting. */ }
    }

    static func estimatedTotal(for mediaDuration: TimeInterval) -> TimeInterval? {
        let ratios = load().compactMap { sample -> Double? in
            guard sample.mediaDuration > 0 else { return nil }
            return sample.processingDuration / sample.mediaDuration
        }.sorted()
        guard ratios.count >= 2 else { return nil }
        let median = ratios[ratios.count / 2]
        return mediaDuration * median
    }

    private static func load() -> [Sample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Sample].self, from: data)) ?? []
    }
}
