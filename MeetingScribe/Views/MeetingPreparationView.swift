import SwiftUI
import UniformTypeIdentifiers

struct MeetingPreparationView: View {
    let input: MeetingInput
    let onStart: (String, RecognitionScenario, MeetingWorkspace?, String, String, String, String, [String], [SupportingMaterial]) -> Void
    let onCancel: () -> Void

    @State private var workspaces: [MeetingWorkspace] = []
    @State private var selectedWorkspaceID: UUID?
    @State private var customerName = ""
    @State private var projectName = ""
    @State private var tagsText = ""
    @State private var tagSuggestions: [String] = []
    @State private var priorRecords: [MeetingRecord] = []
    @State private var materials: [SupportingMaterial] = []
    @State private var extracting = false
    @State private var materialError: String?
    @State private var showNewWorkspace = false
    @State private var newName = ""
    @State private var newCustomerID: UUID?
    @State private var newCustomerName = ""
    @State private var newContext = ""
    @State private var meetingTitle: String
    @State private var meetingContext = ""
    @State private var selectedTemplateID = MinutesTemplate.general.id
    @State private var recognitionScenario: RecognitionScenario
    @State private var showAdvanced = false

    init(input: MeetingInput,
         onStart: @escaping (String, RecognitionScenario, MeetingWorkspace?, String, String, String, String, [String], [SupportingMaterial]) -> Void,
         onCancel: @escaping () -> Void) {
        self.input = input; self.onStart = onStart; self.onCancel = onCancel
        _meetingTitle = State(initialValue: input.primaryURL.deletingPathExtension().lastPathComponent)
        _recognitionScenario = State(initialValue: .autoMultilingual)
    }

    private var selectedWorkspace: MeetingWorkspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    private var customers: [MeetingWorkspace] { workspaces.filter(\.isCustomer) }
    private var projects: [MeetingWorkspace] { workspaces.filter(\.isProject) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("准备会议分析").font(.title3.weight(.medium))
                Text(input.displayName).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()

            Form {
                Section("本次会议") {
                    TextField("会议名称", text: $meetingTitle)
                    Text("使用文件名开始，完成后会自动优化名称。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("本次识别场景", selection: $recognitionScenario) {
                        ForEach(RecognitionScenario.allCases) { scenario in
                            Text(scenario.displayName).tag(scenario)
                        }
                    }
                    Text(recognitionScenario.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("项目") {
                    EditableSuggestionField(title: "客户（可选，留空归入未知）",
                                            text: $customerName,
                                            suggestions: customerSuggestions)
                    EditableSuggestionField(title: "项目名称（可选，留空归入未知）",
                                            text: $projectName,
                                            suggestions: projectSuggestions)
                    TagInputView(text: $tagsText, suggestions: tagSuggestions,
                                 placeholder: "会议类型/标签，例如：双周会")
                    HStack {
                        Button("新建项目…") { showNewWorkspace.toggle() }
                        if let workspace = selectedWorkspace, !workspace.context.isEmpty {
                            Text(workspace.context).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if showNewWorkspace {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("所属客户", selection: $newCustomerID) {
                                    Text("新建客户").tag(UUID?.none)
                                    ForEach(customers) { Text($0.name).tag(Optional($0.id)) }
                                }
                                if newCustomerID == nil {
                                    TextField("新客户名称", text: $newCustomerName)
                                }
                                TextField("项目名称", text: $newName)
                                TextField("长期背景（可选）", text: $newContext)
                                Button("创建并选择") { createWorkspace() }
                                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                              || (newCustomerID == nil
                                                  && newCustomerName.trimmingCharacters(in: .whitespaces).isEmpty))
                            }.padding(4)
                        }
                    }
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

                Section {
                    DisclosureGroup("更多选项", isExpanded: $showAdvanced) {
                        Picker("纪要模板", selection: $selectedTemplateID) {
                            ForEach(MinutesTemplate.all) { Text($0.name).tag($0.id) }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("本次背景（可选）").font(.callout.weight(.medium))
                            TextEditor(text: $meetingContext)
                                .frame(minHeight: 72)
                                .padding(5)
                                .background(.background)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.3))
                                }
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
        .frame(width: 600, height: 510)
        .onAppear(perform: loadWorkspaces)
        .onChange(of: selectedWorkspaceID) { _, id in
            if let workspace = workspaces.first(where: { $0.id == id }) {
                selectedTemplateID = workspace.defaultTemplateID ?? MinutesTemplate.general.id
                projectName = workspace.name
                customerName = customers.first { $0.id == workspace.customerID }?.name ?? ""
            }
        }
        .onChange(of: customerName) { _, _ in syncWorkspace() }
        .onChange(of: projectName) { _, _ in syncWorkspace() }
    }

    private func loadWorkspaces() {
        workspaces = (try? MeetingWorkspaceStore.load()) ?? []
        priorRecords = (try? MeetingHistoryStore.loadAll()) ?? []
        tagSuggestions = MeetingTags.suggestions(from: priorRecords)
    }

    private func createWorkspace() {
        var customerID = newCustomerID
        if customerID == nil {
            let customer = MeetingWorkspace(
                name: newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: .customer)
            workspaces.append(customer)
            customerID = customer.id
        }
        let workspace = MeetingWorkspace(
            name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: .project,
            customerID: customerID,
            context: newContext.trimmingCharacters(in: .whitespacesAndNewlines))
        workspaces.append(workspace)
        do {
            try MeetingWorkspaceStore.save(workspaces)
            selectedWorkspaceID = workspace.id
            showNewWorkspace = false
            newName = ""; newCustomerName = ""; newContext = ""
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
        let tags = MeetingTags.parse(tagsText)
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { materialError = "会议名称不能为空。"; return }
        onStart(title, recognitionScenario, selectedWorkspace,
                meetingContext.trimmingCharacters(in: .whitespacesAndNewlines),
                selectedTemplateID, customerName, projectName,
                tags, materials)
    }

    private var customerSuggestions: [String] {
        MeetingTags.parse((customers.map(\.name) + priorRecords.compactMap(\.customerName))
            .joined(separator: ","))
    }

    private var projectSuggestions: [String] {
        let customer = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let customerIDs = Set(customers.filter {
            $0.name.localizedCaseInsensitiveCompare(customer) == .orderedSame
        }.map(\.id))
        let values = projects.filter { $0.customerID.map(customerIDs.contains) == true }.map(\.name)
            + priorRecords.filter {
                ($0.customerName ?? "").localizedCaseInsensitiveCompare(customer) == .orderedSame
            }.compactMap(\.projectName)
        return MeetingTags.parse(values.joined(separator: ","))
    }

    private func syncWorkspace() {
        let customer = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedWorkspaceID = projects.first { value in
            guard value.name.localizedCaseInsensitiveCompare(project) == .orderedSame,
                  let parent = customers.first(where: { $0.id == value.customerID }) else { return false }
            return parent.name.localizedCaseInsensitiveCompare(customer) == .orderedSame
        }?.id
    }

    private func icon(for kind: SupportingMaterial.Kind) -> String {
        switch kind { case .pdf: return "doc.richtext"; case .text: return "doc.text"; case .image: return "photo" }
    }
}
