import Foundation

enum MeetingSearch {
    static func matches(_ record: MeetingRecord, workspaceName: String?, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let fields = [record.title, record.summaryMarkdown, record.transcript.plainText,
                      workspaceName ?? "",
                      record.customerName ?? "", record.projectName ?? ""]
            + (record.tags ?? []) + Array(record.speakerNames.values)
        return terms.allSatisfy { term in
            fields.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }
}
