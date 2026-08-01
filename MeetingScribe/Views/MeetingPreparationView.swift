import SwiftUI
import UniformTypeIdentifiers

struct MeetingPreparationView: View {
    let mediaURL: URL
    let onStart: (String, MeetingWorkspace?, String, String, [String], [SupportingMaterial]) -> Void
    let onCancel: () -> Void

    @State private var workspaces: [MeetingWorkspace] = []
    @State private var selectedWorkspaceID: UUID?
    @State private var tagsText = ""
    @State private var materials: [SupportingMaterial] = []
    @State private var extracting = false
    @State private var materialError: String?
    @State private var showNewWorkspace = false
    @State private var newName = ""
    @State private var newKind: MeetingWorkspace.Kind = .customer
    @State private var newContext = ""
    @State private var meetingTitle: String
    @State private var meetingContext = ""
    @State private var selectedTemplateID = MinutesTemplate.general.id

    init(mediaURL: URL,
         onStart: @escaping (String, MeetingWorkspace?, String, String, [String], [SupportingMaterial]) -> Void,
         onCancel: @escaping () -> Void) {
        self.mediaURL = mediaURL; self.onStart = onStart; self.onCancel = onCancel
        _meetingTitle = State(initialValue: mediaURL.deletingPathExtension().lastPathComponent)
    }

    private var selectedWorkspace: MeetingWorkspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("准备会议分析").font(.title3.weight(.medium))
                Text(mediaURL.lastPathComponent).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()

            Form {
                Section("本次会议") {
                    TextField("会议名称", text: $meetingTitle)
                    Picker("纪要模板", selection: $selectedTemplateID) {
                        ForEach(MinutesTemplate.all) { Text($0.name).tag($0.id) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("本次背景（可选）")
                            .font(.callout.weight(.medium))
                        TextEditor(text: $meetingContext)
                            .frame(minHeight: 72)
                            .padding(5)
                            .background(.background)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3))
                            }
                            .overlay(alignment: .topLeading) {
                                if meetingContext.isEmpty {
                                    Text("例如：本次目标、当前阶段、需要重点确认的问题或特殊情况")
                                        .font(.callout)
                                        .foregroundStyle(.tertiary)
                                        .padding(11)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                    Text("客户的长期信息放在会议空间背景；这里只填写本次会议独有的信息。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("会议空间") {
                    Picker("归入", selection: $selectedWorkspaceID) {
                        Text("不归组").tag(UUID?.none)
                        ForEach(workspaces) { workspace in
                            Text("\(workspace.kind.label) · \(workspace.name)")
                                .tag(Optional(workspace.id))
                        }
                    }
                    HStack {
                        Button("新建空间…") { showNewWorkspace.toggle() }
                        if let workspace = selectedWorkspace, !workspace.context.isEmpty {
                            Text(workspace.context).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if showNewWorkspace {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("类型", selection: $newKind) {
                                    ForEach(MeetingWorkspace.Kind.allCases) { Text($0.label).tag($0) }
                                }
                                TextField("名称，例如：某银行客户", text: $newName)
                                TextField("长期背景（可选）", text: $newContext)
                                Button("创建并选择") { createWorkspace() }
                                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }.padding(4)
                        }
                    }
                    TextField("标签，用逗号分隔，例如：双周会, 日志治理", text: $tagsText)
                }

                Section("本次会议材料") {
                    if materials.isEmpty {
                        Text("可添加 PDF、TXT、Markdown、CSV、JSON、PNG 或 JPEG。材料只用于本次分析。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(materials) { material in
                            HStack {
                                Label(material.name, systemImage: icon(for: material.kind))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(material.extractedText.count) 字")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button(role: .destructive) {
                                    materials.removeAll { $0.id == material.id }
                                } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        Button("添加材料…") { pickMaterials() }.disabled(extracting)
                        if extracting { ProgressView().controlSize(.small) }
                        if let materialError {
                            Text(materialError).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("开始处理") { start() }
                    .keyboardShortcut(.defaultAction).disabled(extracting)
            }.padding(14)
        }
        .frame(width: 620, height: 590)
        .onAppear(perform: loadWorkspaces)
        .onChange(of: selectedWorkspaceID) { _, id in
            if let workspace = workspaces.first(where: { $0.id == id }) {
                selectedTemplateID = workspace.defaultTemplateID ?? MinutesTemplate.general.id
            }
        }
    }

    private func loadWorkspaces() {
        workspaces = (try? MeetingWorkspaceStore.load()) ?? []
    }

    private func createWorkspace() {
        let workspace = MeetingWorkspace(
            name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: newKind,
            context: newContext.trimmingCharacters(in: .whitespacesAndNewlines))
        workspaces.append(workspace)
        do {
            try MeetingWorkspaceStore.save(workspaces)
            selectedWorkspaceID = workspace.id
            showNewWorkspace = false
            newName = ""; newContext = ""
        } catch {
            materialError = "空间保存失败：\(error.localizedDescription)"
        }
    }

    private func pickMaterials() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MaterialExtractor.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK else { return }
        extracting = true
        materialError = nil
        let urls = panel.urls
        Task {
            var failures: [String] = []
            for url in urls {
                do {
                    var material = try await Task.detached {
                        try MaterialExtractor.extract(from: url)
                    }.value
                    guard materials.count < MaterialExtractor.maxFiles else {
                        failures.append("最多添加 \(MaterialExtractor.maxFiles) 份材料")
                        break
                    }
                    let remaining = MaterialExtractor.totalCharacterLimit
                        - materials.reduce(0) { $0 + $1.extractedText.count }
                    guard remaining > 0 else {
                        failures.append("材料文字总量已达到上限")
                        break
                    }
                    if material.extractedText.count > remaining {
                        material = SupportingMaterial(
                            id: material.id, sourceURL: material.sourceURL, kind: material.kind,
                            extractedText: String(material.extractedText.prefix(remaining)),
                            imageJPEG: material.imageJPEG)
                    }
                    materials.append(material)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            materialError = failures.isEmpty ? nil : failures.joined(separator: "；")
            extracting = false
        }
    }

    private func start() {
        let tags = tagsText.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { materialError = "会议名称不能为空。"; return }
        onStart(title, selectedWorkspace,
                meetingContext.trimmingCharacters(in: .whitespacesAndNewlines),
                selectedTemplateID,
                Array(Set(tags)).sorted(), materials)
    }

    private func icon(for kind: SupportingMaterial.Kind) -> String {
        switch kind { case .pdf: return "doc.richtext"; case .text: return "doc.text"; case .image: return "photo" }
    }
}
