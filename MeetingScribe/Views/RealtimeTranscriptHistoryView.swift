import AppKit
import SwiftUI

struct RealtimeTranscriptHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records = RealtimeTranscriptStore.load()
    @State private var selection: RealtimeTranscriptRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("实时字幕历史").font(.title2.weight(.semibold))
                    Text("字幕在识别过程中持续保存，关闭软件后仍可查看。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开文件夹", systemImage: "folder") {
                    NSWorkspace.shared.open(RealtimeTranscriptStore.directory)
                }
                Button("完成") { dismiss() }
            }
            .padding(18)
            Divider()

            if records.isEmpty {
                ContentUnavailableView("还没有实时字幕记录", systemImage: "captions.bubble")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavigationSplitView {
                    List(records, selection: $selection) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title)
                            HStack {
                                if record.translatedURL != nil { Label("译文", systemImage: "character.book.closed") }
                                if record.audioURL != nil { Label("音频", systemImage: "waveform") }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        .tag(record)
                    }
                    .navigationSplitViewColumnWidth(min: 190, ideal: 220)
                } detail: {
                    if let selection {
                        TranscriptRecordDetail(record: selection)
                    } else {
                        ContentUnavailableView("选择一条记录", systemImage: "text.alignleft")
                    }
                }
            }
        }
        .frame(width: 820, height: 560)
        .onAppear { selection = selection ?? records.first }
    }
}

private struct TranscriptRecordDetail: View {
    let record: RealtimeTranscriptRecord
    @State private var original = ""
    @State private var translated = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("原文").font(.headline)
                Text(original.isEmpty ? "（无内容）" : original).textSelection(.enabled)
                if record.translatedURL != nil {
                    Divider()
                    Text("简体中文翻译").font(.headline)
                    Text(translated.isEmpty ? "（无内容）" : translated)
                        .foregroundStyle(Color.accentColor).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .task(id: record.id) {
            original = (try? String(contentsOf: record.originalURL, encoding: .utf8)) ?? ""
            if let url = record.translatedURL {
                translated = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            } else {
                translated = ""
            }
        }
    }
}
