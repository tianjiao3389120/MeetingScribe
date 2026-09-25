import SwiftUI

struct TranscriptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let record: MeetingRecord
    let onRegenerate: (Transcript) -> Void

    @State private var text: String
    @State private var error: String?
    @State private var selectedCandidate: String?
    @State private var replacement = ""

    init(record: MeetingRecord, onRegenerate: @escaping (Transcript) -> Void) {
        self.record = record
        self.onRegenerate = onRegenerate
        _text = State(initialValue: record.transcript.timecodedText)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("校正识别并重新生成").font(.title3.weight(.medium))
                Text("修改每个时间码后的文字。短词修正会加入识别记忆，下次会议自动使用；请不要增加或删除行。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            Divider()
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("可能的识别错误").font(.caption.weight(.semibold))
                    HStack {
                        ForEach(candidates, id: \.self) { candidate in
                            Button(candidate) {
                                selectedCandidate = candidate
                                replacement = candidate
                            }.buttonStyle(.bordered)
                        }
                        Spacer()
                    }
                    if let selectedCandidate {
                        if !contextSnippets.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("原文上下文").font(.caption2.weight(.semibold))
                                ForEach(Array(contextSnippets.enumerated()), id: \.offset) { _, snippet in
                                    Text(snippet).font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        HStack {
                            Text("将“\(selectedCandidate)”改为")
                            TextField("标准词", text: $replacement)
                                .textFieldStyle(.roundedBorder).frame(width: 180)
                            Button("替换全部") { replaceCandidate(selectedCandidate, with: replacement) }
                                .buttonStyle(.borderedProminent)
                            Button("取消") { self.selectedCandidate = nil }
                                .buttonStyle(.borderless)
                        }
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
            }
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced)).padding(12)
            Divider()
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存修正、学习并重新生成") { regenerate() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(14)
        }.frame(width: 760, height: 640)
    }

    private var candidates: [String] {
        guard let structured = record.structuredSummary else { return [] }
        return RecognitionCandidateExtractor.candidates(from: structured.uncertainties)
    }

    private func replaceCandidate(_ candidate: String, with value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = text.replacingOccurrences(of: candidate, with: trimmed)
        selectedCandidate = nil
    }

    private var contextSnippets: [String] {
        guard let selectedCandidate, !selectedCandidate.isEmpty else { return [] }
        var result: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: selectedCandidate, range: searchStart..<text.endIndex), result.count < 3 {
            let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            result.append("…\(text[start..<end])…")
            searchStart = range.upperBound
        }
        return result
    }

    private func regenerate() {
        guard let transcript = record.transcript.replacingTexts(from: text) else {
            error = "每个原始片段必须保留一行且内容不能为空。"
            return
        }
        let suggestions = RecognitionMemoryStore.correctionSuggestions(
            original: record.transcript, edited: transcript,
            workspaceID: record.workspaceID, sourceTitle: record.title)
        do {
            for value in suggestions { try RecognitionMemoryStore.upsert(value) }
        } catch {
            self.error = "识别记忆保存失败：\(error.localizedDescription)"
            return
        }
        onRegenerate(transcript)
        dismiss()
    }
}
