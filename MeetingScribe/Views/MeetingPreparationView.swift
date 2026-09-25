import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

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
    @State private var newCustomerName = ""
    @State private var newContext = ""
    @State private var meetingTitle: String
    @State private var meetingContext = ""
    @State private var selectedTemplateID = MinutesTemplate.general.id
    @State private var recognitionScenario: RecognitionScenario
    @State private var showAdvanced = false
    @State private var estimatedTokens: Int?
    @State private var showTokenWarning = false

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

    /// Free-form customer/project labels are useful meeting metadata, but project-ledger
    /// updates still need a stable workspace ID. Prefer an exact project selection and
    /// fall back to the matching customer when the typed project has not been created yet.
    private var resolvedWorkspace: MeetingWorkspace? {
        MeetingWorkspaceStore.resolve(
            id: selectedWorkspaceID,
            customerName: customerName,
            projectName: projectName,
            from: workspaces)
    }
    private var formalProject: MeetingWorkspace? {
        resolvedWorkspace?.isProject == true ? resolvedWorkspace : nil
    }

    private var customers: [MeetingWorkspace] { workspaces.filter(\.isCustomer) }
    private var projects: [MeetingWorkspace] { workspaces.filter(\.isProject) }
    private var isExternalTranscript: Bool {
        if case .externalTranscript = input { return true }
        return false
    }

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
                    if isExternalTranscript {
                        LabeledContent("输入类型", value: "外部 SRT 逐字稿")
                        Text("将直接使用现有字幕生成纪要，不会重新转录或分离说话人。附带音频仅作为来源记录保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("本次识别场景", selection: $recognitionScenario) {
                            ForEach(RecognitionScenario.allCases) { scenario in
                                Text(scenario.displayName).tag(scenario)
                            }
                        }
                        Text(recognitionScenario.explanation)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("项目") {
                    Picker("正式项目关联", selection: $selectedWorkspaceID) {
                        Text("不关联项目").tag(UUID?.none)
                        ForEach(projects) { project in
                            let customer = customers.first { $0.id == project.customerID }?.name ?? "未归属客户"
                            Text("\(customer) / \(project.name)").tag(Optional(project.id))
                        }
                    }
                    if formalProject == nil {
                        Button(showNewWorkspace ? "收起新建项目" : "新建项目") {
                            showNewWorkspace.toggle()
                        }
                        if showNewWorkspace {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("客户名称").font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        TextField("请输入客户名称", text: $newCustomerName)
                                            .textFieldStyle(.roundedBorder)
                                            .controlSize(.large)
                                    }

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("项目名称").font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        TextField("请输入项目名称", text: $newName)
                                            .textFieldStyle(.roundedBorder)
                                            .controlSize(.large)
                                    }

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("会议标签").font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        TagInputView(text: $tagsText, suggestions: tagSuggestions,
                                                     placeholder: "输入标签，用逗号分隔")
                                            .controlSize(.large)
                                    }

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("长期背景（可选）").font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        ZStack(alignment: .topLeading) {
                                            TextEditor(text: $newContext)
                                                .scrollContentBackground(.hidden)
                                                .padding(6)
                                                .frame(minHeight: 72)
                                                .background(Color(nsColor: .controlBackgroundColor),
                                                            in: RoundedRectangle(cornerRadius: 7))
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 7)
                                                        .stroke(Color.secondary.opacity(0.28))
                                                }
                                            if newContext.isEmpty {
                                                Text("补充项目背景，帮助后续会议保持上下文")
                                                    .foregroundStyle(.tertiary)
                                                    .padding(.horizontal, 11)
                                                    .padding(.vertical, 10)
                                                    .allowsHitTesting(false)
                                            }
                                        }
                                    }

                                    HStack {
                                        if newCustomerName.trimmingCharacters(in: .whitespaces).isEmpty
                                            || newName.trimmingCharacters(in: .whitespaces).isEmpty {
                                            Text("请填写客户名称和项目名称")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("创建并关联") { createWorkspace() }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.large)
                                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                                      || newCustomerName.trimmingCharacters(
                                                        in: .whitespaces).isEmpty)
                                    }
                                }.padding(8)
                            } label: {
                                Label("创建新的正式项目", systemImage: "folder.badge.plus")
                                    .font(.headline)
                            }
                        }
                    }
                    if formalProject != nil {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("本次会议类型/标签").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TagInputView(text: $tagsText, suggestions: projectTagSuggestions,
                                         placeholder: "例如：双周会、项目汇报",
                                         showsSuggestionsWhenUnfocused: true)
                                .controlSize(.large)
                        }
                    }
                    if let workspace = selectedWorkspace, !workspace.context.isEmpty {
                        Text(workspace.context).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let project = formalProject {
                        Label("已关联正式项目：\(customerName) / \(project.name)",
                              systemImage: "link.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Text("未选择正式项目，本次不会写入项目问题和项目待办。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    DisclosureGroup("更多选项", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("本次会议材料").font(.callout.weight(.medium))
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
                                Button("添加材料…") { pickMaterials() }
                                    .disabled(extracting || materials.count >= MaterialExtractor.maxFiles)
                                if extracting { ProgressView().controlSize(.small) }
                                if let materialError {
                                    Text(materialError).font(.caption).foregroundStyle(.red).lineLimit(2)
                                }
                            }
                        }
                        Divider()
                        Picker("纪要侧重点", selection: $selectedTemplateID) {
                            ForEach(MinutesTemplate.all) { Text($0.name).tag($0.id) }
                        }
                        Text("默认使用通用会议；仅影响本次生成的内容侧重点。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("最终发送给：当前选择的纪要生成模型。")
                            .font(.caption2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("本次补充说明（可选）").font(.callout.weight(.medium))
                            TextEditor(text: $meetingContext)
                                .frame(minHeight: 72)
                                .padding(5)
                                .background(.background)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.3))
                                }
                            Text("仅补充本次会议特有的信息，不会修改项目的长期背景。")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("最终作为本次纪要生成模型的上下文输入。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let preflightError {
                    Label(preflightError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                if let estimatedTokens {
                    Text("预计约 \(estimatedTokens.formatted()) Token")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("按媒体时长、材料文字和最多发送的画面数估算；实际消耗以模型返回为准。")
                }
                Button("取消") { onCancel() }
                Button("开始处理") {
                    if let estimatedTokens,
                       estimatedTokens >= Settings.shared.tokenWarningThreshold {
                        showTokenWarning = true
                    } else { start() }
                }
                    .keyboardShortcut(.defaultAction).disabled(extracting || preflightError != nil)
            }.padding(14)
        }
        .frame(width: 600, height: 510)
        .onAppear(perform: loadWorkspaces)
        .task { await refreshTokenEstimate() }
        .onChange(of: materials.count) { _, _ in Task { await refreshTokenEstimate() } }
        .alert("本次任务预计消耗较高", isPresented: $showTokenWarning) {
            Button("取消", role: .cancel) {}
            Button("仍然开始") { start() }
        } message: {
            Text("预计约 \((estimatedTokens ?? 0).formatted()) Token，已达到提醒阈值 \(Settings.shared.tokenWarningThreshold.formatted())。实际用量可能因模型推理、缓存和图片计费而变化。")
        }
        .onChange(of: selectedWorkspaceID) { _, id in
            if let workspace = workspaces.first(where: { $0.id == id }) {
                showNewWorkspace = false
                projectName = workspace.name
                customerName = customers.first { $0.id == workspace.customerID }?.name ?? ""
            } else {
                projectName = ""
                customerName = ""
            }
        }
    }

    private func loadWorkspaces() {
        workspaces = (try? MeetingWorkspaceStore.load()) ?? []
        priorRecords = (try? MeetingHistoryStore.loadAll()) ?? []
        tagSuggestions = MeetingTags.suggestions(from: priorRecords)
        if case .externalTranscript(let package) = input {
            tagSuggestions = MeetingTags.parse(
                (tagSuggestions + package.metadata.keywords).joined(separator: ","))
        }
    }

    private func createWorkspace() {
        let enteredCustomer = newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines)
        var customerID = customers.first {
            $0.name.localizedCaseInsensitiveCompare(enteredCustomer) == .orderedSame
        }?.id
        if customerID == nil {
            let customer = MeetingWorkspace(
                name: enteredCustomer,
                kind: .customer)
            workspaces.append(customer)
            customerID = customer.id
        }
        let workspace = MeetingWorkspace(
            name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: .project,
            customerID: customerID,
            meetingTypes: MeetingTags.parse(tagsText),
            context: newContext.trimmingCharacters(in: .whitespacesAndNewlines))
        workspaces.append(workspace)
        do {
            try MeetingWorkspaceStore.save(workspaces)
            // Commit the visible classification and stable project selection together.
            // Setting only the ID first makes the text-field onChange handlers race the
            // selection handler and can clear the newly-created project immediately.
            customerName = customers.first { $0.id == customerID }?.name ?? ""
            projectName = workspace.name
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
                        failures.append("\(material.name) 内容超过总量上限，已截取前 \(remaining) 字")
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
        let customer = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { materialError = "会议名称不能为空。"; return }
        onStart(title, recognitionScenario, formalProject,
                meetingContext.trimmingCharacters(in: .whitespacesAndNewlines),
                selectedTemplateID, customer, project,
                tags, materials)
    }

    private func refreshTokenEstimate() async {
        let duration: TimeInterval
        switch input {
        case .media(let url):
            duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 60
        case .externalTranscript(let package):
            let text = (try? String(contentsOf: package.transcriptURL, encoding: .utf8)) ?? ""
            duration = max(60, Double(TokenEstimator.count(text)) / 260 * 60)
        }
        let materialText = materials.map(\.extractedText).joined(separator: "\n")
        let settings = Settings.shared
        estimatedTokens = TokenBudgetEstimator.meeting(
            duration: duration, materialText: materialText,
            includesVision: settings.backend == .openAICompatible && settings.providerSupportsVision,
            frameDensity: settings.frameDensity)
    }

    private var preflightError: String? {
        guard FileManager.default.fileExists(atPath: input.primaryURL.path) else {
            return "源文件已被移动或删除，请重新选择。"
        }
        let settings = Settings.shared
        switch settings.backend {
        case .codexCLI where ToolLocator.path(for: .codex) == nil:
            return "Codex CLI 未安装，请先在设置中配置纪要引擎。"
        case .claudeCLI where ToolLocator.path(for: .claude) == nil:
            return "Claude Code 未安装，请先在设置中配置纪要引擎。"
        case .openAICompatible where settings.providerModel.isEmpty:
            return "尚未选择 API 模型，请先在设置中配置。"
        case .openAICompatible where settings.provider.requiresKey && !settings.providerKeyExists:
            return "纪要引擎缺少 API Key，请先在设置中配置。"
        default: break
        }
        if !isExternalTranscript,
           ToolLocator.path(for: .whisper) == nil || ToolLocator.modelPath() == nil
                || ToolLocator.vadModelPath() == nil {
            return "本地转录引擎未就绪，请先完成 Whisper、模型和 VAD 配置。"
        }
        return nil
    }

    /// A project's choices come from both its configured meeting types and meetings already
    /// filed under that project. This is computed from the current selection so switching
    /// projects immediately switches the visible choices as well.
    private var projectTagSuggestions: [String] {
        guard let project = formalProject else { return [] }
        let customer = customers.first { $0.id == project.customerID }?.name
        let historicalTags = priorRecords.filter { record in
            if record.workspaceID == project.id { return true }
            // Retain compatibility with older records created before stable project IDs.
            return record.workspaceID == nil
                && record.projectName == project.name
                && (customer == nil || record.customerName == customer)
        }.flatMap { $0.tags ?? [] }
        return MeetingTags.parse(
            (project.configuredMeetingTypes + historicalTags).joined(separator: ","))
    }

    private func icon(for kind: SupportingMaterial.Kind) -> String {
        switch kind { case .pdf: return "doc.richtext"; case .text: return "doc.text"; case .image: return "photo" }
    }
}
