import SwiftUI

struct MeetingClassificationView: View {
    let record: MeetingRecord
    let workspaces: [MeetingWorkspace]
    let onSaved: (MeetingRecord) -> Void
    let onCancel: () -> Void

    @State private var workspaceID: UUID?
    @State private var tagsText: String
    @State private var error: String?
    @State private var title: String

    init(record: MeetingRecord, workspaces: [MeetingWorkspace],
         onSaved: @escaping (MeetingRecord) -> Void, onCancel: @escaping () -> Void) {
        self.record = record; self.workspaces = workspaces
        self.onSaved = onSaved; self.onCancel = onCancel
        _workspaceID = State(initialValue: record.workspaceID)
        _tagsText = State(initialValue: (record.tags ?? []).joined(separator: ", "))
        _title = State(initialValue: record.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("会议信息").font(.title3.weight(.medium))
            TextField("会议名称", text: $title)
            Picker("主要空间", selection: $workspaceID) {
                Text("未归组").tag(UUID?.none)
                ForEach(workspaces) { workspace in
                    Text("\(workspace.kind.label) · \(workspace.name)").tag(Optional(workspace.id))
                }
            }
            TextField("标签，用逗号分隔", text: $tagsText)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 480)
    }

    private func save() {
        let tags = tagsText.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTitle.isEmpty else { error = "会议名称不能为空。"; return }
            let updated = try MeetingHistoryStore.updateClassification(
                id: record.id, title: cleanedTitle,
                workspaceID: workspaceID, tags: Array(Set(tags)).sorted())
            onSaved(updated)
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
}
