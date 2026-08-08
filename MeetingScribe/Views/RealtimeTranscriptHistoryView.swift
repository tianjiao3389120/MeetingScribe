import AppKit
import SwiftUI

struct RealtimeTranscriptHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records = RealtimeTranscriptStore.load()
    @State private var selection: RealtimeTranscriptRecord?
    @State private var query = ""
    @State private var renameTitle = ""
    @State private var showRename = false
    @State private var pendingDelete: RealtimeTranscriptRecord?
    @State private var error: String?

    private var filteredRecords: [RealtimeTranscriptRecord] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return records }
        return records.filter {
            $0.title.localizedCaseInsensitiveContains(value)
                || $0.searchableText.localizedCaseInsensitiveContains(value)
        }
    }

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
                if let selection {
                    Button("重命名", systemImage: "pencil") {
                        renameTitle = selection.title
                        showRename = true
                    }
                    Button("导出", systemImage: "square.and.arrow.up") { export(selection) }
                    Button("删除", systemImage: "trash", role: .destructive) {
                        pendingDelete = selection
                    }
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
                    List(filteredRecords, selection: $selection) { record in
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
                    .searchable(text: $query, prompt: "搜索名称或字幕内容")
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
        .alert("重命名实时字幕", isPresented: $showRename) {
            TextField("名称", text: $renameTitle)
            Button("取消", role: .cancel) {}
            Button("保存") { renameSelection() }
        } message: { Text("只修改历史中显示的名称，不会改变字幕或音频内容。") }
        .alert("删除这条实时字幕记录？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) { removePending() }
        } message: { Text("对应的原文、译文和 WAV 音频都会删除，无法恢复。") }
        .alert("操作失败", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func reload(selecting id: String? = nil) {
        records = RealtimeTranscriptStore.load()
        selection = records.first { $0.id == id } ?? records.first
    }

    private func renameSelection() {
        guard let selection else { return }
        do {
            try RealtimeTranscriptStore.rename(selection, to: renameTitle)
            reload(selecting: selection.id)
        } catch { self.error = error.localizedDescription }
    }

    private func removePending() {
        guard let record = pendingDelete else { return }
        pendingDelete = nil
        do {
            try RealtimeTranscriptStore.remove(record)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func export(_ record: RealtimeTranscriptRecord) {
        let panel = NSOpenPanel()
        panel.title = "选择导出文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do { try RealtimeTranscriptStore.export(record, to: directory) }
        catch { self.error = error.localizedDescription }
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
                if let audioURL = record.audioURL {
                    Divider()
                    Button("播放保存的音频", systemImage: "play.circle") {
                        NSWorkspace.shared.open(audioURL)
                    }
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
