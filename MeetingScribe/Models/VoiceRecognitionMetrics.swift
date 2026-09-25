import Foundation

/// Local-only aggregate feedback from explicit speaker confirmation. It stores
/// counts rather than audio, names or embeddings, so thresholds can be tuned
/// without creating another biometric dataset.
struct VoiceRecognitionMetrics: Codable, Sendable, Equatable {
    var reviewedMeetings = 0
    var reviewedClusters = 0
    var automaticPresented = 0
    var automaticConfirmed = 0
    var automaticCorrected = 0
    var suggestionsPresented = 0
    var suggestionsAccepted = 0
    var previouslyUnknownNamed = 0
    var fragmentedMeetings = 0
    var lastUpdatedAt: Date?

    var automaticPrecision: Double? {
        guard automaticPresented > 0 else { return nil }
        return Double(automaticConfirmed) / Double(automaticPresented)
    }

    mutating func record(diarization: Diarization, confirmedNames: [Int: String]) {
        let usable = confirmedNames.compactMap { speaker, rawName -> (Int, String)? in
            let value = HistoricalPersonAffiliations.normalizedName(rawName)
            return value.isEmpty ? nil : (speaker, value)
        }
        guard !usable.isEmpty else { return }
        reviewedMeetings += 1
        reviewedClusters += usable.count
        if diarization.fragmentationWarning != nil { fragmentedMeetings += 1 }
        for (speaker, finalName) in usable {
            if let automatic = diarization.names[speaker] {
                automaticPresented += 1
                if HistoricalPersonAffiliations.normalizedName(automatic) == finalName {
                    automaticConfirmed += 1
                } else {
                    automaticCorrected += 1
                }
            } else if let suggestion = diarization.nameSuggestions[speaker] {
                suggestionsPresented += 1
                if HistoricalPersonAffiliations.normalizedName(suggestion.name) == finalName {
                    suggestionsAccepted += 1
                }
            } else {
                previouslyUnknownNamed += 1
            }
        }
        lastUpdatedAt = Date()
    }
}

enum VoiceRecognitionMetricsStore {
    private static let fileURL = Diarizer.supportDirectory
        .appendingPathComponent("voice-recognition-metrics.json")

    static func load() -> VoiceRecognitionMetrics {
        guard let data = try? Data(contentsOf: fileURL) else { return VoiceRecognitionMetrics() }
        return (try? JSONDecoder().decode(VoiceRecognitionMetrics.self, from: data))
            ?? VoiceRecognitionMetrics()
    }

    static func record(diarization: Diarization, confirmedNames: [Int: String]) throws {
        var metrics = load()
        metrics.record(diarization: diarization, confirmedNames: confirmedNames)
        let data = try JSONEncoder().encode(metrics)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path)
    }

    static func removeAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
