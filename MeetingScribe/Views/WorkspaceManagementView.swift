import SwiftUI

struct WorkspaceManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workspaces: [MeetingWorkspace] = []
    @State private var error: String?
    @State private var originalIDs: Set<UUID> = []
    @State private var pendingDelete: MeetingWorkspace?

    private var customers: [MeetingWorkspace] { workspaces.filter(\.isCustomer) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("项目与会议分组").font(.title3.weight(.medium))
                Text("维护可复用的客户与项目资料；会议类型直接在每场会议的标签中设置。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            List {
                ForEach($workspaces) { $workspace in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Picker("类型", selection: kindBinding(for: workspace.id)) {
                                Text("客户").tag(MeetingWorkspace.Kind.customer)
                                Text("项目").tag(MeetingWorkspace.Kind.project)
                            }
                            .labelsHidden()
                            .frame(width: 82)
                            TextField(workspace.isCustomer ? "客户名称" : "项目名称", text: $workspace.name)
                            Button(role: .destructive) { pendingDelete = workspace } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除分组")
                        }
                        if !workspace.isCustomer {
                            Picker("所属客户", selection: $workspace.customerID) {
                                ForEach(customers) { customer in
                                    Text(customer.name).tag(Optional(customer.id))
                                }
                            }
                        }
                        TextField("长期背景，例如客户身份、产品和项目目标", text: $workspace.context)
                            .font(.caption)
                        Picker("默认纪要模板", selection: Binding(
                            get: { workspace.defaultTemplateID ?? MinutesTemplate.general.id },
                            set: { workspace.defaultTemplateID = $0 }
                        )) {
                            ForEach(MinutesTemplate.all) { Text($0.name).tag($0.id) }
                        }.font(.caption)
                        Picker("默认邮件模板", selection: Binding(
                            get: { workspace.defaultEmailTemplateID
                                ?? EmailTemplate.defaultID(forMinutesTemplateID: workspace.defaultTemplateID) },
                            set: { workspace.defaultEmailTemplateID = $0 }
                        )) {
                            ForEach(EmailTemplate.all) { Text($0.name).tag($0.id) }
                        }.font(.caption)
                    }.padding(.vertical, 5)
                }
                HStack {
                    Button(action: addCustomer) { Label("添加客户", systemImage: "person.badge.plus") }
                    Button(action: addProject) { Label("添加项目", systemImage: "folder.badge.plus") }
                        .disabled(customers.isEmpty)
                }
            }
            Divider()
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并关闭") { saveAndClose() }.keyboardShortcut(.defaultAction)
            }.padding(14)
        }
        .frame(width: 620, height: 480)
        .onAppear {
            workspaces = (try? MeetingWorkspaceStore.load()) ?? []
            originalIDs = Set(workspaces.map(\.id))
        }
        .alert("删除这个项目或会议分组？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let value = pendingDelete { workspaces.removeAll { $0.id == value.id } }
                pendingDelete = nil
            }
        } message: {
            Text("保存后，历史会议仍保留已填写的客户、项目名称和会议类型；仅解除项目资料关联。")
        }
    }

    private func saveAndClose() {
        let invalid = workspaces.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !invalid else { error = "分组名称不能为空。"; return }
        do {
            workspaces = MeetingWorkspaceStore.normalizeHierarchy(workspaces)
            try MeetingWorkspaceStore.save(workspaces)
            let removedIDs = originalIDs.subtracting(workspaces.map(\.id))
            try MeetingHistoryStore.clearWorkspaceReferences(removedIDs)
            originalIDs = Set(workspaces.map(\.id))
            error = nil
            dismiss()
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }

    private func addCustomer() {
        workspaces.append(MeetingWorkspace(name: "新客户", kind: .customer))
    }

    private func addProject() {
        guard let customer = customers.first else { return }
        workspaces.append(MeetingWorkspace(
            name: "新项目", kind: .project, customerID: customer.id))
    }

    private func kindBinding(for id: UUID) -> Binding<MeetingWorkspace.Kind> {
        Binding {
            workspaces.first(where: { $0.id == id })?.kind ?? .project
        } set: { kind in
            guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
            workspaces[index].kind = kind
            if kind == .customer {
                workspaces[index].customerID = nil
                workspaces[index].meetingTypes = nil
            } else if workspaces[index].customerID == nil {
                workspaces[index].customerID = customers.first(where: { $0.id != id })?.id
            }
        }
    }
}
