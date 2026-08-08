import SwiftUI

struct StorageManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var overview = StorageOverview.load()
    @State private var confirmRealtimeRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("存储管理").font(.title3.weight(.medium))
                Text("历史纪要和托管材料不会随缓存清理而删除。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            Form {
                Section("历史资料库") {
                    LabeledContent("会议") { Text("\(overview.meetingCount) 场") }
                    LabeledContent("占用空间") { Text(bytes(overview.historyBytes)) }
                    if overview.missingSourceCount > 0 {
                        Label("\(overview.missingSourceCount) 场会议的原始音视频已移动；纪要和托管材料仍可查看。",
                              systemImage: "questionmark.folder")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("在 Finder 中打开资料库") {
                        try? FileManager.default.createDirectory(
                            at: MeetingHistoryStore.defaultDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(MeetingHistoryStore.defaultDirectory)
                    }
                }
                Section("处理缓存") {
                    LabeledContent("转录与说话人缓存") {
                        Text("\(overview.cacheCount) 份 · \(bytes(overview.cacheBytes))")
                    }
                    Button("清除处理缓存", role: .destructive) {
                        TranscriptCache.clear(); DiarizationCache.clear(); refresh()
                    }.disabled(overview.cacheCount == 0)
                    Text("清除后重新处理同一个音视频时需要再次转录和分离说话人。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("实时字幕记录") {
                    LabeledContent("记录") {
                        Text("\(overview.realtimeCount) 场 · \(bytes(overview.realtimeBytes))")
                    }
                    Button("打开实时字幕目录") {
                        try? RealtimeTranscriptStore.prepareDirectory()
                        NSWorkspace.shared.open(RealtimeTranscriptStore.directory)
                    }
                    Button("删除全部实时字幕记录", role: .destructive) {
                        confirmRealtimeRemoval = true
                    }
                    .disabled(overview.realtimeCount == 0)
                    Text("包含实时字幕原文、译文和 WAV 音频；删除不会影响会议资料库。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("说话人运行环境") {
                    LabeledContent("占用空间") { Text(bytes(overview.speakerRuntimeBytes)) }
                    Text("如不再使用说话人分离，可在设置的“说话人分离”区域卸载。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Divider()
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
                .padding(14)
        }.frame(width: 540, height: 500)
        .alert("删除全部实时字幕记录？", isPresented: $confirmRealtimeRemoval) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive) {
                try? RealtimeTranscriptStore.removeAll()
                refresh()
            }
        } message: {
            Text("所有实时字幕原文、译文和 WAV 音频都会删除，无法恢复；会议资料库不受影响。")
        }
    }

    private func refresh() { overview = StorageOverview.load() }
    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
