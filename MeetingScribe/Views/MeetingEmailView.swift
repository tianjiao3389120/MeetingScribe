import SwiftUI
import UniformTypeIdentifiers

struct MeetingEmailView: View {
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID
    let title: String
    let workspaceName: String?
    let minutesTemplateID: String?
    let workspaceEmailTemplateID: String?
    let minutes: String
    let initialDrafts: MeetingEmailDrafts?
    var onSaved: ((MeetingEmailDrafts) -> Void)?

    @State private var chinese: String
    @State private var traditional: String
    @State private var tone: MeetingEmailGenerator.Tone
    @State private var audience: MeetingEmailGenerator.Audience
    @State private var emailTemplateID: String
    @State private var version: Version = .chinese
    @State private var working = false
    @State private var message: String?

    private enum Version: String, CaseIterable { case chinese = "中文", traditional = "香港繁体" }

    init(meetingID: UUID, title: String, workspaceName: String? = nil,
         minutesTemplateID: String? = nil, workspaceEmailTemplateID: String? = nil,
         minutes: String,
         initialDrafts: MeetingEmailDrafts? = nil,
         onSaved: ((MeetingEmailDrafts) -> Void)? = nil) {
        self.meetingID = meetingID; self.title = title; self.workspaceName = workspaceName
        self.minutesTemplateID = minutesTemplateID
        self.workspaceEmailTemplateID = workspaceEmailTemplateID
        self.minutes = minutes
        self.initialDrafts = initialDrafts; self.onSaved = onSaved
        _chinese = State(initialValue: initialDrafts?.chinese ?? "")
        _traditional = State(initialValue: initialDrafts?.hongKongTraditional ?? "")
        _tone = State(initialValue: MeetingEmailGenerator.Tone(rawValue: initialDrafts?.tone ?? "") ?? .natural)
        _audience = State(initialValue: MeetingEmailGenerator.Audience(rawValue: initialDrafts?.audience ?? "") ?? .customer)
        _emailTemplateID = State(initialValue: initialDrafts?.templateID
            ?? workspaceEmailTemplateID
            ?? EmailTemplate.defaultID(forMinutesTemplateID: minutesTemplateID))
    }

    private var currentText: Binding<String> {
        version == .chinese ? $chinese : $traditional
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("会议同步邮件").font(.title3.weight(.medium))
                Text(title).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            Divider()

            VStack(spacing: 10) {
                HStack {
                    Picker("邮件模板", selection: $emailTemplateID) {
                        ForEach(EmailTemplate.all) { Text($0.name).tag($0.id) }
                    }
                    Spacer()
                    Picker("", selection: $version) {
                        ForEach(Version.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
                HStack {
                    Picker("收件人", selection: $audience) {
                        ForEach(MeetingEmailGenerator.Audience.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("语气", selection: $tone) {
                        ForEach(MeetingEmailGenerator.Tone.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Spacer()
                }
            }.padding(14)

            Text("当前模板：\(EmailTemplate.template(id: emailTemplateID).instructions) 请核对中文稿后再生成香港繁体。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 8)

            TextEditor(text: currentText)
                .font(.body).padding(10)
                .overlay {
                    if currentText.wrappedValue.isEmpty {
                        ContentUnavailableView(
                            version == .chinese ? "尚未生成中文邮件" : "请先确认中文邮件",
                            systemImage: "envelope")
                            .allowsHitTesting(false)
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
                Button("生成中文邮件") { generateChinese() }.disabled(working)
                Button("生成香港繁体") { generateTraditional() }
                    .disabled(working || chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("复制") { copyCurrent() }.disabled(currentText.wrappedValue.isEmpty)
                Menu("导出…") {
                    Button("纯文本（.txt）") { exportCurrent(extension: "txt") }
                    Button("Markdown（.md）") { exportCurrent(extension: "md") }
                }.disabled(currentText.wrappedValue.isEmpty)
                Button("保存草稿") { save() }.disabled(chinese.isEmpty && traditional.isEmpty)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
        }
        .frame(width: 760, height: 600)
        .onAppear(perform: loadSavedDrafts)
    }

    private func generateChinese() {
        working = true; message = "正在根据会议纪要生成…"
        Task {
            do {
                chinese = try await MeetingEmailGenerator(settings: .shared)
                    .generateChinese(title: title, workspaceName: workspaceName,
                                     minutes: minutes,
                                     template: EmailTemplate.template(id: emailTemplateID),
                                     tone: tone, audience: audience)
                traditional = ""; version = .chinese
                try persist(); message = "中文草稿已生成并保存，请核对后再生成香港繁体。"
            } catch { message = "失败：\(error.localizedDescription)" }
            working = false
        }
    }

    private func generateTraditional() {
        working = true; message = "正在转换为香港繁体商务表达…"
        let confirmed = chinese
        Task {
            do {
                traditional = try await MeetingEmailGenerator(settings: .shared)
                    .generateHongKongTraditional(from: confirmed)
                version = .traditional
                try persist(); message = "香港繁体草稿已生成并保存。"
            } catch { message = "失败：\(error.localizedDescription)" }
            working = false
        }
    }

    private func save() {
        do { try persist(); message = "草稿已保存到会议历史。" }
        catch { message = "失败：\(error.localizedDescription)" }
    }

    private func persist() throws {
        let drafts = MeetingEmailDrafts(
            chinese: chinese, hongKongTraditional: traditional,
            tone: tone.rawValue, audience: audience.rawValue,
            templateID: emailTemplateID)
        _ = try MeetingHistoryStore.updateEmailDrafts(id: meetingID, drafts: drafts)
        onSaved?(drafts)
    }

    private func copyCurrent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentText.wrappedValue, forType: .string)
        message = "已复制。"
    }

    private func exportCurrent(extension fileExtension: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = fileExtension == "md"
            ? [UTType(filenameExtension: "md") ?? .plainText] : [.plainText]
        panel.nameFieldStringValue = "\(title) 同步邮件-\(version.rawValue).\(fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try currentText.wrappedValue.write(to: url, atomically: true, encoding: .utf8)
            message = "已导出到 \(url.path)"
        } catch { message = "失败：\(error.localizedDescription)" }
    }

    private func loadSavedDrafts() {
        guard initialDrafts == nil, chinese.isEmpty, traditional.isEmpty,
              let drafts = (try? MeetingHistoryStore.loadAll())?.first(where: { $0.id == meetingID })?.emailDrafts
        else { return }
        chinese = drafts.chinese; traditional = drafts.hongKongTraditional
        tone = MeetingEmailGenerator.Tone(rawValue: drafts.tone) ?? .natural
        audience = MeetingEmailGenerator.Audience(rawValue: drafts.audience) ?? .customer
        emailTemplateID = drafts.templateID
            ?? workspaceEmailTemplateID
            ?? EmailTemplate.defaultID(forMinutesTemplateID: minutesTemplateID)
    }
}
