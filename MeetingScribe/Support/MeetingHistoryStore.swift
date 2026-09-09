import Foundation

enum MeetingHistoryStore {
    struct LoadIssue: Identifiable, Sendable {
        var id: String { directory.path }
        let directory: URL
        let reason: String
    }

    struct LoadReport: Sendable {
        let records: [MeetingRecord]
        let issues: [LoadIssue]
    }
    enum Failure: LocalizedError {
        case noStructuredActions
        case actionNotFound
        case emptyAction
        case suggestionNotFound
        case trackedActionNotFound

        var errorDescription: String? {
            switch self {
            case .noStructuredActions: return "这场会议没有可编辑的结构化待办。"
            case .actionNotFound: return "待办已经变化，请重新打开后再试。"
            case .emptyAction: return "待办内容不能为空。"
            case .suggestionNotFound: return "状态建议已经变化，请重新打开后再试。"
            case .trackedActionNotFound: return "找不到建议对应的历史待办。"
            }
        }
    }
    static let defaultDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/Meetings", isDirectory: true)
    }()

    static func save(_ sourceRecord: MeetingRecord, root: URL = defaultDirectory,
                     materialSources: [SupportingMaterial] = []) throws {
        var record = sourceRecord
        let directory = root.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: directory.path)

        if !materialSources.isEmpty {
            let materialsDirectory = directory.appendingPathComponent("materials", isDirectory: true)
            try FileManager.default.createDirectory(at: materialsDirectory,
                                                    withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: materialsDirectory.path)
            var references: [MaterialReference] = []
            for (index, material) in materialSources.enumerated() {
                let safeName = material.name.replacingOccurrences(
                    of: #"[^\p{L}\p{N}._-]"#,
                    with: "_", options: .regularExpression)
                let destination = materialsDirectory.appendingPathComponent(
                    String(format: "%02d-%@", index + 1, safeName))
                if material.sourceURL.standardizedFileURL != destination.standardizedFileURL {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: material.sourceURL, to: destination)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                      ofItemAtPath: destination.path)
                references.append(MaterialReference(name: material.name, kind: material.kind,
                                                    sourcePath: destination.path))
            }
            record.materials = references
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try secureWrite(encoder.encode(record),
                        to: directory.appendingPathComponent("metadata.json"))
        try secureWrite(Data(record.summaryMarkdown.utf8),
                        to: directory.appendingPathComponent("minutes.md"))
        try secureWrite(encoder.encode(record.transcript),
                        to: directory.appendingPathComponent("transcript.json"))
        if let structured = record.structuredSummary {
            try secureWrite(encoder.encode(structured),
                            to: directory.appendingPathComponent("minutes.json"))
        }
    }

    static func loadAll(root: URL = defaultDirectory) throws -> [MeetingRecord] {
        try loadReport(root: root).records
    }

    static func loadReport(root: URL = defaultDirectory) throws -> LoadReport {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return LoadReport(records: [], issues: [])
        }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [MeetingRecord] = []
        var issues: [LoadIssue] = []
        for directory in directories {
            let url = directory.appendingPathComponent("metadata.json")
            do {
                let data = try Data(contentsOf: url)
                let record = try decoder.decode(MeetingRecord.self, from: data)
                guard record.schemaVersion <= MeetingRecord.currentSchemaVersion else {
                    issues.append(LoadIssue(directory: directory, reason: "记录来自更高版本的应用"))
                    continue
                }
                records.append(record)
            } catch {
                issues.append(LoadIssue(directory: directory, reason: error.localizedDescription))
            }
        }
        return LoadReport(records: records.sorted { $0.createdAt > $1.createdAt }, issues: issues)
    }

    static func updateSourcePath(id: UUID, sourcePath: String,
                                 root: URL = defaultDirectory) throws -> MeetingRecord {
        let url = root.appendingPathComponent(id.uuidString).appendingPathComponent("metadata.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: url))
        record.sourcePath = sourcePath
        try save(record, root: root)
        return record
    }

    static func updateSpeakers(id: UUID, names: [Int: String], roles: [Int: SpeakerRole],
                               root: URL = defaultDirectory) throws -> MeetingRecord {
        let url = root.appendingPathComponent(id.uuidString).appendingPathComponent("metadata.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: url))
        record.speakerNames = names
        record.speakerRoles = roles.filter { $0.value.isSpecified }
        try save(record, root: root)
        return record
    }

    static func remove(id: UUID, root: URL = defaultDirectory) throws {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    static func updateClassification(id: UUID, title: String? = nil,
                                     createdAt: Date? = nil,
                                     workspaceID: UUID?, customerName: String? = nil,
                                     projectName: String? = nil, tags: [String],
                                     root: URL = defaultDirectory) throws -> MeetingRecord {
        let url = root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("metadata.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let target = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: url))
        let sourceKey = target.sourceURL.standardizedFileURL.path
        var updatedTarget = target
        for var record in try loadAll(root: root) where
            record.sourceURL.standardizedFileURL.path == sourceKey {
            if record.id == id {
                if let title { record.title = title }
                if let createdAt { record.createdAt = createdAt }
            }
            record.workspaceID = workspaceID
            record.customerName = cleanedClassification(customerName)
            record.projectName = cleanedClassification(projectName)
            record.tags = tags
            try save(record, root: root)
            if record.id == id { updatedTarget = record }
        }
        return updatedTarget
    }

    private static func cleanedClassification(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    static func clearWorkspaceReferences(_ workspaceIDs: Set<UUID>,
                                         root: URL = defaultDirectory) throws {
        guard !workspaceIDs.isEmpty else { return }
        for var record in try loadAll(root: root) where
            record.workspaceID.map(workspaceIDs.contains) == true {
            record.workspaceID = nil
            try save(record, root: root)
        }
    }

    static func updateTranslations(id: UUID, translations: [TranscriptTranslation],
                                   root: URL = defaultDirectory) throws -> MeetingRecord {
        let url = root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("metadata.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: url))
        record.transcriptTranslations = translations
        try save(record, root: root)
        return record
    }

    static func updateEmailDrafts(id: UUID, drafts: MeetingEmailDrafts,
                                  root: URL = defaultDirectory) throws -> MeetingRecord {
        let url = root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("metadata.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: url))
        record.emailDrafts = drafts
        try save(record, root: root)
        return record
    }

    static func updateLibraryState(id: UUID, favorite: Bool? = nil,
                                   archived: Bool? = nil,
                                   root: URL = defaultDirectory) throws -> MeetingRecord {
        let url = root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("metadata.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: url))
        if let favorite { record.isFavorite = favorite }
        if let archived { record.isArchived = archived }
        try save(record, root: root)
        return record
    }

    static func updateActionItem(id: UUID, index: Int,
                                 action: StructuredMinutes.ActionItem,
                                 root: URL = defaultDirectory) throws -> MeetingRecord {
        let url = root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("metadata.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: url))
        guard var structured = record.structuredSummary else { throw Failure.noStructuredActions }
        guard structured.actionItems.indices.contains(index) else { throw Failure.actionNotFound }
        var cleaned = action
        cleaned.task = action.task.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.owner = action.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.due = action.due.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.status = action.status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.task.isEmpty else { throw Failure.emptyAction }
        structured.actionItems[index] = cleaned
        record.structuredSummary = structured
        record.summaryMarkdown = StructuredMinutesRenderer.markdown(from: structured)
        try save(record, root: root)
        return record
    }

    static func applyActionSuggestion(sourceMeetingID: UUID, suggestionID: UUID,
                                      root: URL = defaultDirectory) throws -> [MeetingRecord] {
        let records = try loadAll(root: root)
        guard var source = records.first(where: { $0.id == sourceMeetingID }),
              let suggestion = source.actionStatusSuggestions?.first(where: { $0.id == suggestionID })
        else { throw Failure.suggestionNotFound }
        if source.appliedActionSuggestionIDs?.contains(suggestionID) == true { return [source] }
        guard var target = records.first(where: { $0.id == suggestion.targetMeetingID }),
              var structured = target.structuredSummary,
              let index = structured.actionItems.indices.first(where: {
                  ActionTracking.id(for: structured.actionItems[$0], meetingID: target.id, index: $0)
                      == suggestion.targetActionID
              }) else { throw Failure.trackedActionNotFound }

        structured.actionItems[index].trackingID = suggestion.targetActionID
        structured.actionItems[index].status = suggestion.proposedStatus
        target.structuredSummary = structured
        target.summaryMarkdown = StructuredMinutesRenderer.markdown(from: structured)
        try save(target, root: root)

        var applied = source.appliedActionSuggestionIDs ?? []
        applied.append(suggestionID)
        source.appliedActionSuggestionIDs = applied
        try save(source, root: root)
        return [target, source]
    }

    static func updateActionSuggestions(id: UUID, suggestions: [ActionStatusSuggestion],
                                        root: URL = defaultDirectory) throws -> MeetingRecord {
        let url = root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("metadata.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: url))
        record.actionStatusSuggestions = suggestions
        try save(record, root: root)
        return record
    }

    static func export(_ record: MeetingRecord, to directory: URL) throws {
        let base = record.title
        try StructuredMinutesRenderer.markdown(for: record).write(
            to: directory.appendingPathComponent("\(base) 纪要.md"),
            atomically: true, encoding: .utf8)
        try record.transcript.timecodedText.write(
            to: directory.appendingPathComponent("\(base) 逐字稿.txt"),
            atomically: true, encoding: .utf8)
        if let structured = record.structuredSummary {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(structured).write(
                to: directory.appendingPathComponent("\(base) 纪要.json"), options: .atomic)
        }
    }

    private static func secureWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }
}
