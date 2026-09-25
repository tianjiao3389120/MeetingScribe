import SwiftUI
import UniformTypeIdentifiers

/// Read, edit, copy and export the externally safe meeting minutes.
struct MeetingMinutesVersionView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State private var minutes: String
    @State private var message: String?
    @State private var editing = false

    init(title: String, minutes: String) {
        self.title = title
        _minutes = State(initialValue: minutes)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("会议纪要").font(.title3.weight(.medium))
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            Divider()

            Text("已隐藏内部判断、证据、会后非正式内容和模型不确定项。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)

            if editing {
                TextEditor(text: $minutes).font(.body).padding(10)
            } else {
                MarkdownView(markdown: minutes)
            }

            Divider()
            HStack(spacing: 10) {
                if let message {
                    Text(message).font(.caption)
                        .foregroundStyle(message.hasPrefix("失败") ? .red : .secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button(editing ? "预览" : "编辑内容") { editing.toggle() }
                    .disabled(minutes.trimmed.isEmpty)
                Button("复制") { copyMinutes() }.disabled(minutes.trimmed.isEmpty)
                Button("用 Markdown 应用打开") { openMinutes() }
                    .disabled(minutes.trimmed.isEmpty)
                Menu("导出…") {
                    Button("Markdown（.md）") { exportMinutes(extension: "md") }
                    Button("纯文本（.txt）") { exportMinutes(extension: "txt") }
                }.disabled(minutes.trimmed.isEmpty)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 760, height: 600)
    }

    private func copyMinutes() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(minutes, forType: .string)
        message = "已复制。"
    }

    private func openMinutes() {
        do {
            try MinutesDocumentOpener.open(markdown: minutes, title: "\(title) 会议纪要")
        } catch {
            message = "失败：\(error.localizedDescription)"
        }
    }

    private func exportMinutes(extension fileExtension: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = fileExtension == "md"
            ? [UTType(filenameExtension: "md") ?? .plainText] : [.plainText]
        panel.nameFieldStringValue = "\(title) 会议纪要.\(fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try minutes.write(to: url, atomically: true, encoding: .utf8)
            message = "已导出到 \(url.path)"
        } catch {
            message = "失败：\(error.localizedDescription)"
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
