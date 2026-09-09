import Foundation

enum StructuredMinutesRenderer {
    /// Re-render persisted structured data so presentation fixes also apply to
    /// existing meetings. Legacy unstructured records keep their saved text.
    static func markdown(for record: MeetingRecord) -> String {
        guard let structured = record.structuredSummary else { return record.summaryMarkdown }
        return markdown(from: structured)
    }

    static func markdown(from value: StructuredMinutes) -> String {
        var lines = ["# \(value.title.isEmpty ? "会议纪要" : value.title)"]

        let metadata = [
            value.nature.isEmpty ? nil : "**性质**：\(value.nature)",
            meetingDurationForDisplay(value.duration).map { "**时长**：\($0)" },
        ].compactMap { $0 }
        if !metadata.isEmpty { lines += ["", metadata.joined(separator: "  \n")] }
        if !value.agenda.isEmpty {
            lines += ["", "**议程**："]
            lines += value.agenda.enumerated().map { "\($0.offset + 1). \($0.element)" }
        }

        if !value.participantAssessment.isEmpty {
            lines += ["", "## 参会角色判断", ""]
            lines += value.participantAssessment.map { "- \($0)" }
        }

        if !value.issues.isEmpty {
            lines += ["", "## 一、问题与进展"]
            for issue in value.issues {
                let status = issue.status.isEmpty ? "" : " [\(issue.status)]"
                lines += ["", "### \(issue.title)\(status)"]
                append(label: "背景", value: issue.background ?? "", evidence: [], to: &lines)
                append(label: "根因", value: issue.rootCause, evidence: issue.evidence, to: &lines)
                append(label: "方案", value: issue.solution, evidence: [], to: &lines)
                append(label: "本次进展", value: issue.progress, evidence: [], to: &lines)
            }
        }

        if !value.requirements.isEmpty {
            lines += ["", "## 二、需求", "", "| 需求 | 状态 | 时程 | 证据 |",
                      "|---|---|---|---|"]
            lines += value.requirements.map {
                "| \(cell($0.title)) | \(cell($0.status)) | \(cell($0.schedule)) | \(cell($0.evidence.joined(separator: "、"))) |"
            }
        }

        if !value.actionItems.isEmpty || !value.agreements.isEmpty {
            lines += ["", "## 三、待办事项"]
            let grouped = Dictionary(grouping: value.actionItems) { item in
                item.owner.isEmpty ? "待明确" : item.owner
            }
            for owner in grouped.keys.sorted() {
                lines += ["", "### \(owner)"]
                lines += (grouped[owner] ?? []).map { item in
                    let status = item.status.isEmpty ? "" : " [\(item.status)]"
                    let due = item.due.isEmpty ? "" : "（\(item.due)）"
                    return "- [\(item.isClosed ? "x" : " ")] \(item.task)\(due)\(status)\(evidenceSuffix(item.evidence))"
                }
            }
            if !value.agreements.isEmpty {
                lines += ["", "### 协作约定"]
                lines += value.agreements.map { "- \($0.content)\(evidenceSuffix($0.evidence))" }
            }
        }

        if !value.afterMeeting.isEmpty {
            lines += ["", "## 四、会后（非正式内容）", ""]
            lines += value.afterMeeting.map { "- \($0.content)\(evidenceSuffix($0.evidence))" }
        }

        if !value.uncertainties.isEmpty {
            lines += ["", "> 需要人工核对："]
            lines += value.uncertainties.map {
                let label = $0.uncertaintyKind == .speechRecognition ? "识别模糊"
                    : ($0.uncertaintyKind == .unclearMeaning ? "含义不明" : "待确认")
                return "> - [\(label)] \($0.content)\(evidenceSuffix($0.evidence))"
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func append(label: String, value: String, evidence: [String],
                               to lines: inout [String]) {
        guard !value.isEmpty else { return }
        lines.append("- **\(label)**：\(value)\(evidenceSuffix(evidence))")
    }

    private static func evidenceSuffix(_ values: [String]) -> String {
        values.isEmpty ? "" : "（证据：\(values.joined(separator: "、"))）"
    }

    private static func cell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// Deterministic external view of the internal minutes. Sensitive sections and
/// raw evidence are removed in code, so a model cannot accidentally reintroduce
/// them while drafting the customer email.
enum CustomerMinutesRenderer {
    static func markdown(for record: MeetingRecord) -> String {
        guard let structured = record.structuredSummary else {
            return sanitizedLegacyMarkdown(record.summaryMarkdown)
        }
        return markdown(from: structured)
    }

    static func markdown(from value: StructuredMinutes) -> String {
        var lines = ["# \(value.title.isEmpty ? "会议纪要" : value.title)"]
        let metadata = [
            value.nature.isEmpty ? nil : "**性质**：\(value.nature)",
            meetingDurationForDisplay(value.duration).map { "**时长**：\($0)" },
        ].compactMap { $0 }
        if !metadata.isEmpty { lines += ["", metadata.joined(separator: "  \n")] }
        if !value.agenda.isEmpty {
            lines += ["", "**议程**："]
            lines += value.agenda.enumerated().map { "\($0.offset + 1). \($0.element)" }
        }

        if !value.issues.isEmpty {
            lines += ["", "## 一、问题与进展"]
            for issue in value.issues {
                let status = issue.status.isEmpty ? "" : " [\(issue.status)]"
                lines += ["", "### \(issue.title)\(status)"]
                append(label: "背景", value: issue.background ?? "", to: &lines)
                append(label: "根因", value: issue.rootCause, to: &lines)
                append(label: "方案", value: issue.solution, to: &lines)
                append(label: "本次进展", value: issue.progress, to: &lines)
            }
        }

        if !value.requirements.isEmpty {
            lines += ["", "## 二、需求", "", "| 需求 | 状态 | 时程 |", "|---|---|---|"]
            lines += value.requirements.map {
                "| \(cell($0.title)) | \(cell($0.status)) | \(cell($0.schedule)) |"
            }
        }

        if !value.actionItems.isEmpty || !value.agreements.isEmpty {
            lines += ["", "## 三、待办事项"]
            let grouped = Dictionary(grouping: value.actionItems) {
                $0.owner.isEmpty ? "待明确" : $0.owner
            }
            for owner in grouped.keys.sorted() {
                lines += ["", "### \(owner)"]
                lines += (grouped[owner] ?? []).map { item in
                    let status = item.status.isEmpty ? "" : " [\(item.status)]"
                    let due = item.due.isEmpty ? "" : "（\(item.due)）"
                    return "- [\(item.isClosed ? "x" : " ")] \(item.task)\(due)\(status)"
                }
            }
            if !value.agreements.isEmpty {
                lines += ["", "### 协作约定"]
                lines += value.agreements.map { "- \($0.content)" }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func append(label: String, value: String, to lines: inout [String]) {
        guard !value.isEmpty else { return }
        lines.append("- **\(label)**：\(value)")
    }

    private static func cell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Best-effort compatibility for old records saved before structured
    /// minutes existed. New records always use the field-level renderer above.
    private static func sanitizedLegacyMarkdown(_ markdown: String) -> String {
        let hiddenHeadings = ["参会角色判断", "会后（非正式内容）", "需要人工核对"]
        var hiding = false
        return markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { raw -> String? in
                let line = String(raw)
                if line.hasPrefix("## ") {
                    hiding = hiddenHeadings.contains { line.contains($0) }
                    return hiding ? nil : line
                }
                if hiding { return nil }
                if line.contains("证据：") {
                    return line.replacingOccurrences(
                        of: "（证据：[^）]*）", with: "", options: .regularExpression)
                }
                return line
            }
            .joined(separator: "\n")
    }
}

/// The model may report both the media length and the effective meeting time.
/// Minutes should show only the latter; a simple duration remains unchanged.
private func meetingDurationForDisplay(_ rawValue: String) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    guard let marker = value.range(of: "正式会议") else { return value }

    var formal = String(value[marker.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if formal.hasPrefix("时长") { formal.removeFirst(2) }
    formal = formal.trimmingCharacters(in: CharacterSet(charactersIn: " ：:"))
    if let separator = formal.firstIndex(where: { "；;，,\n".contains($0) }) {
        formal = String(formal[..<separator])
    }
    formal = formal.trimmingCharacters(in: .whitespacesAndNewlines)
    return formal.isEmpty ? value : formal
}
