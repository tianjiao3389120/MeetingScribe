import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var apiKey = Settings.shared.apiKey ?? ""
    @State private var modelStatus = ModelStatus.check()
    @State private var download: ModelDownloader?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("生成纪要") {
                    Picker("后端", selection: $settings.backend) {
                        ForEach(BackendKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.radioGroup)

                    Text(settings.backend.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    switch settings.backend {
                    case .claudeCLI:
                        ToolRow(tool: .claude)
                    case .anthropicAPI:
                        SecureField("API key", text: $apiKey, prompt: Text("sk-ant-…"))
                            .onChange(of: apiKey) { _, new in settings.apiKey = new }
                        Picker("模型", selection: $settings.apiModel) {
                            Text("Claude Opus 5（最强）").tag("claude-opus-5")
                            Text("Claude Sonnet 5（更快更省）").tag("claude-sonnet-5")
                        }
                    }
                }

                Section("转录") {
                    ToolRow(tool: .whisper)

                    LabeledContent("识别模型") {
                        switch modelStatus {
                        case .ready:
                            Label("已就绪", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .missing:
                            if let download, download.isDownloading {
                                VStack(alignment: .trailing, spacing: 4) {
                                    ProgressView(value: download.progress).frame(width: 160)
                                    Text(download.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Button("下载（约 1.5GB）") {
                                    let downloader = ModelDownloader()
                                    download = downloader
                                    Task {
                                        await downloader.run()
                                        modelStatus = ModelStatus.check()
                                    }
                                }
                            }
                        }
                    }

                    Picker("语言", selection: $settings.language) {
                        Text("中文").tag("zh")
                        Text("英文").tag("en")
                        Text("自动检测").tag("auto")
                    }
                }

                Section("画面分析") {
                    Picker("采样密度", selection: $settings.frameDensity) {
                        ForEach(FrameDensity.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text("屏幕共享的文档、告警列表、架构图是音频里没有的事实来源。相同画面会自动合并，只保留内容真正变化的那些。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("会议背景") {
                    TextEditor(text: $settings.contextHint)
                        .frame(height: 52)
                        .font(.callout)
                    Text("例如：与银行客户的双周例会，我方是安全产品厂商。填了能明显提升纪要质量。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("领域词表") {
                    TextEditor(text: $settings.glossary)
                        .frame(height: 110)
                        .font(.system(.caption, design: .monospaced))
                    HStack {
                        Text("写成通顺的句子而非散词罗列，170 字以内。发现新错词就补进来。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") { settings.glossary = Settings.defaultGlossary }
                            .buttonStyle(.link)
                    }
                }

                Section {
                    Toggle("保留中间文件（音轨、截图）", isOn: $settings.keepIntermediates)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 640)
    }
}

private struct ToolRow: View {
    let tool: ToolLocator.Tool

    var body: some View {
        LabeledContent(tool.displayName) {
            if let path = ToolLocator.path(for: tool) {
                Label(path, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Label("未安装", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(tool.installHint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private enum ModelStatus {
    case ready, missing

    static func check() -> ModelStatus {
        ToolLocator.modelPath() != nil ? .ready : .missing
    }
}

/// Downloads the whisper transcription and VAD models on demand.
@Observable
@MainActor
final class ModelDownloader {
    var isDownloading = false
    var progress: Double = 0
    var detail = ""

    func run() async {
        isDownloading = true
        defer { isDownloading = false }

        try? FileManager.default.createDirectory(at: ToolLocator.modelDirectory,
                                                 withIntermediateDirectories: true)

        detail = "下载识别模型…"
        await fetch(ToolLocator.transcriptionModelURL,
                    to: ToolLocator.modelDirectory.appendingPathComponent(ToolLocator.transcriptionModel))

        detail = "下载 VAD 模型…"
        await fetch(ToolLocator.vadModelURL,
                    to: ToolLocator.modelDirectory.appendingPathComponent(ToolLocator.vadModel))

        detail = "完成"
        progress = 1
    }

    private func fetch(_ urlString: String, to destination: URL) async {
        guard !FileManager.default.fileExists(atPath: destination.path),
              let url = URL(string: urlString) else { return }
        do {
            let (temp, _) = try await URLSession.shared.download(from: url)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            detail = "下载失败：\(error.localizedDescription)"
        }
    }
}
