import SwiftUI

struct WorkspaceManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workspaces: [MeetingWorkspace] = []
    @State private var error: String?
    @State private var saved = false
    @State private var originalIDs: Set<UUID> = []
    @State private var pendingDelete: MeetingWorkspace?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("会议空间").font(.title3.weight(.medium))
                Text("空间背景会自动用于该空间后续会议；标签仍可按单次会议填写。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            List {
                ForEach($workspaces) { $workspace in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Picker("", selection: $workspace.kind) {
                                ForEach(MeetingWorkspace.Kind.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().frame(width: 105)
                            TextField("空间名称", text: $workspace.name)
                            Button(role: .destructive) { pendingDelete = workspace } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除空间")
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
                Button { workspaces.append(MeetingWorkspace(name: "新空间", kind: .project)) } label: {
                    Label("添加空间", systemImage: "plus")
                }
            }
            Divider()
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                else if saved { Label("已保存", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
                Spacer()
                Button("完成") { dismiss() }
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }.padding(14)
        }
        .frame(width: 620, height: 480)
        .onAppear {
            workspaces = (try? MeetingWorkspaceStore.load()) ?? []
            originalIDs = Set(workspaces.map(\.id))
        }
        .alert("删除这个会议空间？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let value = pendingDelete { workspaces.removeAll { $0.id == value.id } }
                pendingDelete = nil
                saved = false
            }
        } message: {
            Text("保存后，该空间下的历史会议会保留并自动改为“未归组”。")
        }
    }

    private func save() {
        let invalid = workspaces.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !invalid else { error = "空间名称不能为空。"; return }
        do {
            try MeetingWorkspaceStore.save(workspaces)
            let removedIDs = originalIDs.subtracting(workspaces.map(\.id))
            try MeetingHistoryStore.clearWorkspaceReferences(removedIDs)
            originalIDs = Set(workspaces.map(\.id))
            error = nil; saved = true
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
}
