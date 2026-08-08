import Foundation

enum MeetingDateResolver {
    static func recordedAt(for url: URL, fallback: Date = Date()) -> Date {
        recordedAtIfAvailable(for: url) ?? fallback
    }

    static func recordedAtIfAvailable(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey,
                                                       .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}
