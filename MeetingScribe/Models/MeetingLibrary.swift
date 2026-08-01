import Foundation

enum MeetingLibraryScope: Hashable {
    case all, recent, pendingActions, favorites, ungrouped, archived, workspace(UUID)
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
            }
        }
    }
}
