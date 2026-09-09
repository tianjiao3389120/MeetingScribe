import Foundation
import AVFoundation

enum MeetingDateResolver {
    static func recordedAt(for url: URL, fallback: Date = Date()) -> Date {
        recordedAtIfAvailable(for: url) ?? fallback
    }

    static func recordedAtIfAvailable(for url: URL) -> Date? {
        if let embedded = embeddedCreationDate(for: url) { return embedded }
        if let filename = filenameDate(for: url) { return filename }
        let values = try? url.resourceValues(forKeys: [.creationDateKey,
                                                       .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    private static func embeddedCreationDate(for url: URL) -> Date? {
        let supported = ["m4a", "mp3", "wav", "aac", "caf", "mov", "mp4", "m4v"]
        guard supported.contains(url.pathExtension.lowercased()) else { return nil }
        let asset = AVURLAsset(url: url)
        // This synchronous access keeps date resolution available to importers that are not
        // async. AVFoundation still exposes the embedded QuickTime/MP4 creation date here.
        return asset.commonMetadata.first(where: { $0.commonKey == .commonKeyCreationDate })?.dateValue
    }

    static func filenameDate(for url: URL, calendar: Calendar = .current) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        let patterns: [(String, String)] = [
            (#"(?<!\d)(\d{4})[-_.年](\d{1,2})[-_.月](\d{1,2})(?:日)?[ T_-]+(\d{1,2})[.:时-](\d{1,2})(?:[.:分-](\d{1,2}))?"#,
             "datetime"),
            (#"(?<!\d)(\d{4})(\d{2})(\d{2})[ T_-]?(\d{2})(\d{2})(\d{2})(?!\d)"#,
             "datetime"),
            (#"(?<!\d)(\d{4})[-_.年](\d{1,2})[-_.月](\d{1,2})(?:日)?(?!\d)"#,
             "date"),
        ]
        for (pattern, kind) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: name, range: NSRange(name.startIndex..., in: name)) else { continue }
            func number(_ index: Int) -> Int? {
                guard match.range(at: index).location != NSNotFound,
                      let range = Range(match.range(at: index), in: name) else { return nil }
                return Int(name[range])
            }
            guard let year = number(1), let month = number(2), let day = number(3) else { continue }
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year; components.month = month; components.day = day
            if kind == "datetime" {
                components.hour = number(4) ?? 0
                components.minute = number(5) ?? 0
                components.second = number(6) ?? 0
            } else {
                components.hour = 0; components.minute = 0; components.second = 0
            }
            if let date = calendar.date(from: components) { return date }
        }
        return nil
    }
}
