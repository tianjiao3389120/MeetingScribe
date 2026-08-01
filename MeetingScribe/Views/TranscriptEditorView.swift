import SwiftUI

struct TranscriptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let record: MeetingRecord
    let onRegenerate: (Transcript) -> Void

    @State private var text: String
    @State private var error: String?

    init(record: MeetingRecord, onRegenerate: @escaping (Transcript) -> Void) {
        self.record = record
        self.onRegenerate = onRegenerate
        _text = State(initialValue: record.transcript.timecodedText)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("校正逐字稿").font(.title3.weight(.medium))
                Text("修改每个时间码后的文字。请不要增加或删除行；重新生成不会再次运行语音识别。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            Divider()
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced)).padding(12)
            Divider()
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("取消") { dismiss() }
                Button("用修正版重新生成") { regenerate() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(14)
        }.frame(width: 760, height: 640)
    }

    private func regenerate() {
        guard let transcript = record.transcript.replacingTexts(from: text) else {
            error = "每个原始片段必须保留一行且内容不能为空。"
            return
        }
        onRegenerate(transcript)
        dismiss()
    }
}
