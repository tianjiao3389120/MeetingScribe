import Foundation

enum MeetingLibraryScope: Hashable {
    case all, recent, pendingActions, favorites, ungrouped, archived, workspace(UUID), meetingTag(String)
}

enum MeetingLibrarySort: String, CaseIterable, Identifiable {
    case newest, oldest, title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: return "最新优先"
        case .oldest: return "最早优先"
        case .title: return "按名称"
        }
    }
}

struct MeetingLibrarySection: Identifiable {
    let id: String
    let title: String
    let records: [MeetingRecord]
}

enum MeetingLibrary {
    static func filter(_ records: [MeetingRecord], scope: MeetingLibraryScope,
                       now: Date = Date()) -> [MeetingRecord] {
        records.filter { record in
            switch scope {
            case .archived: return record.isArchived == true
            case .all: return record.isArchived != true
            case .recent:
                return record.isArchived != true
                    && record.createdAt >= Calendar.current.date(byAdding: .day, value: -30, to: now)!
            case .pendingActions: return record.isArchived != true && record.openActionCount > 0
            case .favorites: return record.isArchived != true && record.isFavorite == true
            case .ungrouped: return record.isArchived != true && record.workspaceID == nil
            case .workspace(let id): return record.isArchived != true && record.workspaceID == id
            case .meetingTag(let tag):
                return record.isArchived != true && (record.tags ?? []).contains {
                    $0.localizedCaseInsensitiveCompare(tag) == .orderedSame
                }
            }
        }
    }

    static func sorted(_ records: [MeetingRecord], by sort: MeetingLibrarySort) -> [MeetingRecord] {
        records.sorted { lhs, rhs in
            switch sort {
            case .newest:
                return lhs.createdAt > rhs.createdAt
            case .oldest:
                return lhs.createdAt < rhs.createdAt
            case .title:
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                return comparison == .orderedSame
                    ? lhs.createdAt > rhs.createdAt
                    : comparison == .orderedAscending
            }
        }
    }

    static func timeSections(_ records: [MeetingRecord], sort: MeetingLibrarySort,
                             now: Date = Date(), calendar: Calendar = .current) -> [MeetingLibrarySection] {
        let values = sorted(records, by: sort)
        guard sort != .title else {
            return values.isEmpty ? [] : [MeetingLibrarySection(id: "name", title: "按名称", records: values)]
        }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        var buckets: [String: [MeetingRecord]] = [:]

        for record in values {
            let key: String
            if record.createdAt >= startOfToday {
                key = "today"
            } else if record.createdAt >= startOfYesterday {
                key = "yesterday"
            } else if record.createdAt >= startOfWeek {
                key = "week"
            } else {
                key = "earlier"
            }
            buckets[key, default: []].append(record)
        }

        let orderedKeys = sort == .oldest
            ? ["earlier", "week", "yesterday", "today"]
            : ["today", "yesterday", "week", "earlier"]
        let titles = ["today": "今天", "yesterday": "昨天", "week": "本周", "earlier": "更早"]
        return orderedKeys.compactMap { key in
            guard let records = buckets[key], !records.isEmpty else { return nil }
            return MeetingLibrarySection(id: key, title: titles[key]!, records: records)
        }
    }
}
