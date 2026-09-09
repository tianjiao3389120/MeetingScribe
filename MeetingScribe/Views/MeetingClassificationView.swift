import SwiftUI

struct MeetingClassificationView: View {
    let record: MeetingRecord
    let workspaces: [MeetingWorkspace]
    let records: [MeetingRecord]
    let tagSuggestions: [String]
    let onSaved: (MeetingRecord) -> Void
    let onCancel: () -> Void

    @State private var workspaceID: UUID?
    @State private var tagsText: String
    @State private var customerName: String
    @State private var projectName: String
    @State private var error: String?
    @State private var title: String

    init(record: MeetingRecord, workspaces: [MeetingWorkspace], records: [MeetingRecord],
         tagSuggestions: [String],
         onSaved: @escaping (MeetingRecord) -> Void, onCancel: @escaping () -> Void) {
        self.record = record; self.workspaces = workspaces; self.records = records
        self.tagSuggestions = tagSuggestions
        self.onSaved = onSaved; self.onCancel = onCancel
        let initialProjectID = workspaces.contains {
            $0.id == record.workspaceID && $0.isProject
        } ? record.workspaceID : nil
        _workspaceID = State(initialValue: initialProjectID)
        _customerName = State(initialValue: record.customerName ?? "")
        _projectName = State(initialValue: record.projectName ?? "")
        _tagsText = State(initialValue: (record.tags ?? []).joined(separator: ", "))
        _title = State(initialValue: record.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("会议信息").font(.title3.weight(.medium))
            TextField("会议名称", text: $title)
            EditableSuggestionField(title: "客户（未填写时归入未知）",
                                    text: $customerName, suggestions: customerSuggestions)
            EditableSuggestionField(title: "项目名称（未填写时归入未知）",
                                    text: $projectName, suggestions: projectSuggestions)
            TagInputView(text: $tagsText, suggestions: tagSuggestions,
                         placeholder: "会议类型/标签，例如：双周会")
            Text("会议类型直接使用标签，可填写一个或多个。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 480)
        .onChange(of: customerName) { _, _ in syncWorkspace() }
        .onChange(of: projectName) { _, _ in syncWorkspace() }
    }

    private func save() {
        let tags = MeetingTags.parse(tagsText)
        do {
            let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTitle.isEmpty else { error = "会议名称不能为空。"; return }
            let updated = try MeetingHistoryStore.updateClassification(
                id: record.id, title: cleanedTitle,
                workspaceID: workspaceID, customerName: customerName,
                projectName: projectName, tags: tags)
            onSaved(updated)
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }

    private var customerSuggestions: [String] {
        let values = workspaces.filter(\.isCustomer).map(\.name)
            + records.compactMap(\.customerName)
        return MeetingTags.parse(values.joined(separator: ","))
    }

    private var projectSuggestions: [String] {
        let key = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let customerIDs = Set(workspaces.filter {
            $0.isCustomer && $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame
        }.map(\.id))
        let values = workspaces.filter { $0.isProject && $0.customerID.map(customerIDs.contains) == true }.map(\.name)
            + records.filter { ($0.customerName ?? "").localizedCaseInsensitiveCompare(key) == .orderedSame }
                .compactMap(\.projectName)
        return MeetingTags.parse(values.joined(separator: ","))
    }

    private func syncWorkspace() {
        let customer = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaceID = workspaces.first { value in
            guard value.isProject,
                  value.name.localizedCaseInsensitiveCompare(project) == .orderedSame,
                  let parent = workspaces.first(where: { $0.id == value.customerID }) else { return false }
            return parent.name.localizedCaseInsensitiveCompare(customer) == .orderedSame
        }?.id
    }
}
