import SwiftUI

struct ActionItemEditorView: View {
    let initial: StructuredMinutes.ActionItem
    let onSave: (StructuredMinutes.ActionItem) -> Void
    let onCancel: () -> Void

    @State private var task: String
    @State private var owner: String
    @State private var due: String
    @State private var status: String

    private let commonStatuses = ["待处理", "进行中", "阻塞", "已完成", "已关闭"]

    init(action: StructuredMinutes.ActionItem,
         onSave: @escaping (StructuredMinutes.ActionItem) -> Void,
         onCancel: @escaping () -> Void) {
        initial = action; self.onSave = onSave; self.onCancel = onCancel
        _task = State(initialValue: action.task)
        _owner = State(initialValue: action.owner)
        _due = State(initialValue: action.due)
        _status = State(initialValue: action.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑待办").font(.title3.weight(.medium))
            Form {
                TextField("待办内容", text: $task, axis: .vertical).lineLimit(2...5)
                TextField("责任人或责任方", text: $owner)
                TextField("截止时间", text: $due)
                Picker("状态", selection: $status) {
                    if !status.isEmpty && !commonStatuses.contains(status) {
                        Text(status).tag(status)
                    }
                    Text("待确认").tag("")
                    ForEach(commonStatuses, id: \.self) { Text($0).tag($0) }
                }
                if !initial.evidence.isEmpty {
                    LabeledContent("原始证据", value: initial.evidence.joined(separator: "、"))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("保存") {
                    var value = initial
                    value.task = task; value.owner = owner; value.due = due; value.status = status
                    onSave(value)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500, height: 390)
    }
}
