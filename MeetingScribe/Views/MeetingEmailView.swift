import SwiftUI
import UniformTypeIdentifiers

/// Presents the normal, externally safe minutes and an optional Hong Kong
/// business-language edition. The historical draft container is retained for
/// backward-compatible persistence, but no email is generated.
struct MeetingMinutesVersionView: View {
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID
    let title: String
    let minutes: String
    let initialDrafts: MeetingEmailDrafts?
    var onSaved: ((MeetingEmailDrafts) -> Void)?

    @State private var standardMinutes: String
    @State private var hongKongMinutes: String
    @State private var version: Version = .standard
    @State private var working = false
    @State private var message: String?
    @State private var editing = false
    @State private var hongKongUsage: GenerationUsage?

    private enum Version: String, CaseIterable {
        case standard = "会议纪要"
        case hongKong = "香港版本纪要"
    }

    init(meetingID: UUID, title: String, minutes: String,
         initialDrafts: MeetingEmailDrafts? = nil,
         onSaved: ((MeetingEmailDrafts) -> Void)? = nil) {
        self.meetingID = meetingID
        self.title = title
        self.minutes = minutes
        self.initialDrafts = initialDrafts
        self.onSaved = onSaved
        _standardMinutes = State(initialValue: minutes)
        _hongKongMinutes = State(initialValue: initialDrafts?.hongKongTraditional ?? "")
        _hongKongUsage = State(initialValue: initialDrafts?.hongKongUsage)
    }

    private var currentText: Binding<String> {
        version == .standard ? $standardMinutes : $hongKongMinutes
    }

    private var hongKongEstimate: Int {
        TokenEstimator.count(HongKongMinutesGenerator.systemPrompt + "\n" + standardMinutes)
            + max(500, TokenEstimator.count(standardMinutes))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("会议纪要").font(.title3.weight(.medium))
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            Divider()

            HStack {
                Picker("", selection: $version) {
                    ForEach(Version.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 310)
                Spacer()
                if version == .hongKong {
                    Text("预计约 \(hongKongEstimate.formatted()) Token")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(hongKongMinutes.isEmpty ? "生成香港版本纪要" : "重新生成") {
                        generateHongKongMinutes()
                    }
                    .disabled(working || standardMinutes.trimmed.isEmpty)
                }
            }
            .padding(14)

            Text(version == .standard
                 ? "已隐藏内部判断、证据、会后非正式内容和模型不确定项。"
                 : "按香港商务书面语、项目沟通习惯及常用术语改写；事实、责任人、日期和承诺保持不变。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 8)

            if version == .hongKong, let usage = hongKongUsage {
                Text("本次转换：约 \(usage.totalTokens.formatted()) Token · \(usage.calls) 次调用")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }

            if !editing && !currentText.wrappedValue.isEmpty {
                MarkdownView(markdown: currentText.wrappedValue)
            } else {
                TextEditor(text: currentText).font(.body).padding(10)
                    .overlay {
                        if currentText.wrappedValue.isEmpty {
                            ContentUnavailableView("尚未生成香港版本纪要",
                                                   systemImage: "character.book.closed")
                                .allowsHitTesting(false)
                        }
                    }
            }

            Divider()
            HStack(spacing: 10) {
                if let message {
                    Text(message).font(.caption)
                        .foregroundStyle(message.hasPrefix("失败") ? .red : .secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(editing ? "预览" : "编辑内容") { editing.toggle() }
                    .disabled(currentText.wrappedValue.isEmpty)
                Button("复制") { copyCurrent() }.disabled(currentText.wrappedValue.isEmpty)
                Button("用 Markdown 应用打开") { openCurrent() }
                    .disabled(currentText.wrappedValue.isEmpty)
                Menu("导出…") {
                    Button("Markdown（.md）") { exportCurrent(extension: "md") }
                    Button("纯文本（.txt）") { exportCurrent(extension: "txt") }
                }.disabled(currentText.wrappedValue.isEmpty)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 760, height: 600)
    }

    private func generateHongKongMinutes() {
        working = true
        message = "正在生成香港版本纪要…"
        Task {
            do {
                let context = TokenUsageContext(
                    feature: "生成香港版本纪要", meetingID: meetingID,
                    meetingTitle: title)
                hongKongMinutes = try await TokenUsageContext.$current.withValue(context) {
                    try await HongKongMinutesGenerator(settings: .shared)
                        .generateHongKongMinutes(from: standardMinutes)
                }
                hongKongUsage = GenerationUsage(
                    phases: [GenerationUsage.estimatedPhase(
                        name: "香港版本纪要",
                        input: HongKongMinutesGenerator.systemPrompt + "\n" + standardMinutes,
                        output: hongKongMinutes)],
                    isEstimated: true)
                version = .hongKong
                try persist()
                message = "香港版本纪要已生成并保存，请核对后使用。"
            } catch {
                message = "失败：\(error.localizedDescription)"
            }
            working = false
        }
    }

    private func persist() throws {
        let old = initialDrafts
        let drafts = MeetingEmailDrafts(
            chinese: old?.chinese ?? "", hongKongTraditional: hongKongMinutes,
            tone: old?.tone ?? "自然", audience: old?.audience ?? "客户",
            templateID: old?.templateID, hongKongUsage: hongKongUsage)
        _ = try MeetingHistoryStore.updateEmailDrafts(id: meetingID, drafts: drafts)
        onSaved?(drafts)
    }

    private func copyCurrent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentText.wrappedValue, forType: .string)
        message = "已复制。"
    }

    private func openCurrent() {
        do {
            try MinutesDocumentOpener.open(markdown: currentText.wrappedValue,
                                           title: "\(title) \(version.rawValue)")
        } catch {
            message = "失败：\(error.localizedDescription)"
        }
    }

    private func exportCurrent(extension fileExtension: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = fileExtension == "md"
            ? [UTType(filenameExtension: "md") ?? .plainText] : [.plainText]
        panel.nameFieldStringValue = "\(title) \(version.rawValue).\(fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try currentText.wrappedValue.write(to: url, atomically: true, encoding: .utf8)
            message = "已导出到 \(url.path)"
        } catch {
            message = "失败：\(error.localizedDescription)"
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
