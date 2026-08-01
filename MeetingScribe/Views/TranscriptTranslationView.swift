import SwiftUI

struct TranscriptTranslationView: View {
    @Environment(\.dismiss) private var dismiss
    let record: MeetingRecord
    let onSaved: (MeetingRecord) -> Void

    @State private var translations: [TranscriptTranslation]
    @State private var running = false
    @State private var progress = ""
    @State private var error: String?
    @State private var generationTask: Task<Void, Never>?

    init(record: MeetingRecord, onSaved: @escaping (MeetingRecord) -> Void) {
        self.record = record; self.onSaved = onSaved
        _translations = State(initialValue: record.transcriptTranslations ?? [])
    }

    private var byID: [Int: String] {
        Dictionary(uniqueKeysWithValues: translations.map { ($0.segmentID, $0.text) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("粤语 / 普通话双栏逐字稿").font(.title3.weight(.medium))
                    Text("原文永久保留；释义使用当前设置中的纪要模型按需生成。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if running { ProgressView().controlSize(.small); Text(progress).font(.caption) }
                if running {
                    Button("取消") { generationTask?.cancel() }
                } else {
                    Button(translations.isEmpty ? "生成简体中文释义" : "重新生成") { generate() }
                }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            HStack {
                Text("原始识别").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                Text("简体中文释义").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 18).padding(.vertical, 9)
            Divider()
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).padding(12)
            }
            List(record.transcript.segments) { segment in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("[\(segment.timecode)]").font(.caption).foregroundStyle(.secondary)
                        Text(segment.text).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    Text(byID[segment.id] ?? (running ? "生成中…" : "尚未生成"))
                        .foregroundStyle(byID[segment.id] == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 5)
            }
        }.frame(width: 900, height: 680)
            .onDisappear { generationTask?.cancel() }
    }

    private func generate() {
        running = true; error = nil; progress = "准备中…"
        generationTask = Task {
            do {
                let result = try await TranscriptTranslator(settings: Settings.shared)
                    .run(transcript: record.transcript) { done, total in
                        Task { @MainActor in progress = "第 \(done) / \(total) 批" }
                    }
                let updated = try MeetingHistoryStore.updateTranslations(
                    id: record.id, translations: result)
                translations = result
                onSaved(updated)
            } catch is CancellationError {
                progress = "已取消"
            } catch { self.error = error.localizedDescription }
            running = false
            generationTask = nil
        }
    }
}
