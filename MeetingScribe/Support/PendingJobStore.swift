import Foundation

enum PendingJobStore {
    static let fileURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingScribe/pending-job.json")

    static func save(_ job: PendingMeetingJob, to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(job).write(to: url, options: .atomic)
    }

    static func load(from url: URL = fileURL) -> PendingMeetingJob? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingMeetingJob.self, from: data)
    }

    static func clear(id: UUID? = nil, at url: URL = fileURL) {
        if let id, load(from: url)?.id != id { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum PendingIssueReviewStore {
    static let fileURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingScribe/pending-issue-review.json")

    static func save(_ draft: PendingIssueReviewDraft, to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(draft).write(to: url, options: .atomic)
    }

    static func load(from url: URL = fileURL) -> PendingIssueReviewDraft? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingIssueReviewDraft.self, from: data)
    }

    static func clear(at url: URL = fileURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
