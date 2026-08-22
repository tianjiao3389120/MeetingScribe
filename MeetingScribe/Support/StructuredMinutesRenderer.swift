import Foundation

enum StructuredMinutesRenderer {
    static func markdown(from value: StructuredMinutes) -> String {
        var lines = ["# \(value.title.isEmpty ? "会议纪要" : value.title)"]

        let metadata = [
            value.nature.isEmpty ? nil : "**性质**：\(value.nature)",
            value.duration.isEmpty ? nil : "**时长**：\(value.duration)",
            value.agenda.isEmpty ? nil : "**议程**：\(value.agenda.joined(separator: "；"))",
        ].compactMap { $0 }
        if !metadata.isEmpty { lines += ["", metadata.joined(separator: "  \n")] }

        if !value.participantAssessment.isEmpty {
            lines += ["", "## 参会角色判断", ""]
            lines += value.participantAssessment.map { "- \($0)" }
        }

        if !value.issues.isEmpty {
            lines += ["", "## 一、问题与进展"]
            for issue in value.issues {
                let status = issue.status.isEmpty ? "" : " [\(issue.status)]"
                lines += ["", "### \(issue.title)\(status)"]
                append(label: "根因", value: issue.rootCause, evidence: issue.evidence, to: &lines)
                append(label: "方案", value: issue.solution, evidence: [], to: &lines)
                append(label: "现状", value: issue.progress, evidence: [], to: &lines)
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
