import Foundation

struct TokenUsageContext: Sendable {
    let feature: String
    var customer: String? = nil
    var project: String? = nil
    var meetingID: UUID? = nil
    var meetingTitle: String? = nil

    @TaskLocal static var current: TokenUsageContext?

    func replacingFeature(_ value: String) -> TokenUsageContext {
        TokenUsageContext(feature: value, customer: customer, project: project,
                          meetingID: meetingID, meetingTitle: meetingTitle)
    }
}

struct TokenUsageEntry: Codable, Identifiable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case succeeded, failed, cancelled }

    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let feature: String
    let customer: String?
    let project: String?
    let meetingID: UUID?
    let meetingTitle: String?
    let backend: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let isEstimated: Bool
    let status: Status
    let errorMessage: String?

    var totalTokens: Int { inputTokens + outputTokens }
}

enum TokenUsageLedger {
    private static let lock = NSLock()
    static let defaultURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingScribe/token-usage.json")

    static func load(from url: URL = defaultURL) -> [TokenUsageEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TokenUsageEntry].self, from: data)) ?? []
    }

    static func append(_ entry: TokenUsageEntry, to url: URL = defaultURL) {
        lock.lock(); defer { lock.unlock() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var entries = (try? Data(contentsOf: url)).flatMap {
            try? decoder.decode([TokenUsageEntry].self, from: $0)
        } ?? []
        entries.append(entry)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func record(startedAt: Date, backend: String, model: String,
                       inputTokens: Int, outputTokens: Int, isEstimated: Bool,
                       status: TokenUsageEntry.Status, error: Error? = nil) {
        let context = TokenUsageContext.current
        append(TokenUsageEntry(
            id: UUID(), startedAt: startedAt, finishedAt: Date(),
            feature: context?.feature ?? "未分类模型调用",
            customer: context?.customer, project: context?.project,
            meetingID: context?.meetingID, meetingTitle: context?.meetingTitle,
            backend: backend, model: model, inputTokens: inputTokens,
            outputTokens: outputTokens, isEstimated: isEstimated, status: status,
            errorMessage: error?.localizedDescription))
    }
}

enum TokenBudgetEstimator {
    static func meeting(duration: TimeInterval, materialText: String,
                        includesVision: Bool, frameDensity: FrameDensity) -> Int {
        let transcript = Int(ceil(max(duration, 60) / 60 * 260))
        let materials = TokenEstimator.count(materialText)
        let output = 2_500
        let planning = frameDensity == .off ? 0 : min(2_500, transcript / 5 + 500)
        let images = includesVision && frameDensity != .off ? 12 * 900 : 0
        return transcript + materials + output + planning + images
    }
}
