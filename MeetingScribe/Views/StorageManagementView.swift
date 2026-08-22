import SwiftUI
import UniformTypeIdentifiers

struct StorageManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var overview = StorageOverview.load()
    @State private var pendingRestore: URL?
    @State private var backupMessage: String?
    @State private var backupError: String?
    @State private var backupBusy = false
    @State private var automaticBackup = AutomaticBackupConfiguration.load()
    @State private var automaticBackupMessage: String?

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
                Section("备份与恢复") {
                    HStack {
                        Button("创建完整备份…") { chooseBackupDestination() }
                        Button("从备份恢复…") { chooseRestoreArchive() }
                    }
                    .disabled(backupBusy)
                    if backupBusy { ProgressView().controlSize(.small) }
                    if let message = backupError ?? backupMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(backupError == nil ? Color.secondary : Color.red)
                            .textSelection(.enabled)
                    }
                    Text("备份包含会议、托管材料、会议空间、反馈和声纹档案；不包含缓存、识别引擎或 API Key。恢复只合并新项目，不覆盖现有数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("自动备份") {
                    Toggle("启用自动备份", isOn: Binding(
                        get: { automaticBackup.enabled },
                        set: { automaticBackup.enabled = $0; saveAutomaticBackup() }
                    ))
                    Picker("频率", selection: Binding(
                        get: { automaticBackup.frequency },
                        set: { automaticBackup.frequency = $0; saveAutomaticBackup() }
                    )) {
                        ForEach(AutomaticBackupFrequency.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    Stepper("保留最近 \(automaticBackup.retentionCount) 份",
                            value: Binding(
                                get: { automaticBackup.retentionCount },
                                set: { automaticBackup.retentionCount = $0; saveAutomaticBackup() }
                            ), in: 1...30)
                    LabeledContent("备份目录") {
                        Text(automaticBackup.directoryPath.isEmpty
                             ? "尚未选择" : automaticBackup.directoryPath)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    HStack {
                        Button("选择 iCloud Drive 文件夹…") { chooseAutomaticBackupDirectory() }
                        Button("立即备份") { runAutomaticBackupNow() }
                            .disabled(automaticBackup.directoryPath.isEmpty || backupBusy)
                    }
                    if let automaticBackupMessage {
                        Text(automaticBackupMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("应用启动或完成一场会议后检查备份周期。软件关闭时不会在后台运行；iCloud 离线时下次启动会自动重试。")
                        .font(.caption).foregroundStyle(.secondary)
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
                Section("说话人运行环境") {
                    LabeledContent("占用空间") { Text(bytes(overview.speakerRuntimeBytes)) }
                    Text("如不再使用说话人分离，可在设置的“说话人分离”区域卸载。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Divider()
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
                .padding(14)
        }.frame(width: 580, height: 720)
        .onAppear { automaticBackupMessage = AutomaticBackupManager.lastMessage }
        .alert("从备份恢复？", isPresented: Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        )) {
            Button("取消", role: .cancel) { pendingRestore = nil }
            Button("合并恢复") { restoreSelectedArchive() }
        } message: {
            Text("恢复会添加备份中不存在于当前资料库的项目；已有会议、空间和文件不会被覆盖。")
        }
    }

    private func refresh() { overview = StorageOverview.load() }
    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func chooseBackupDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "MeetingScribe 备份 \(day).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupBusy = true; backupError = nil; backupMessage = nil
        Task {
            do {
                try await Task.detached { try LibraryBackup.createArchive(at: url) }.value
                backupMessage = "备份已保存到：\(url.path)"
            } catch { backupError = error.localizedDescription }
            backupBusy = false
        }
    }

    private func chooseRestoreArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        pendingRestore = panel.url
    }

    private func restoreSelectedArchive() {
        guard let url = pendingRestore else { return }
        pendingRestore = nil
        backupBusy = true; backupError = nil; backupMessage = nil
        Task {
            do {
                let result = try await Task.detached {
                    try LibraryBackup.restoreArchive(from: url)
                }.value
                backupMessage = result.message
                refresh()
            } catch { backupError = error.localizedDescription }
            backupBusy = false
        }
    }

    private func saveAutomaticBackup() {
        automaticBackup.save()
    }

    private func chooseAutomaticBackupDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择备份目录"
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: iCloud.path) { panel.directoryURL = iCloud }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        automaticBackup.directoryPath = url.path
        saveAutomaticBackup()
    }

    private func runAutomaticBackupNow() {
        saveAutomaticBackup()
        backupBusy = true
        Task {
            automaticBackupMessage = await AutomaticBackupManager.runIfNeeded(force: true)
            backupBusy = false
        }
    }
}
