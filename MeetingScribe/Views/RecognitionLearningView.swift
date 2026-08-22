import SwiftUI

struct RecognitionLearningView: View {
    let workspaceID: UUID?
    let sourceTitle: String
    let uncertainties: [StructuredMinutes.EvidenceItem]
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mistaken = ""
    @State private var canonical = ""
    @State private var kind: RecognitionMemoryEntry.Kind = .term
    @State private var projectOnly = true
    @State private var saved: [RecognitionMemoryEntry] = []
    @State private var inlineCorrections: [String: String] = [:]
    @State private var inlineProjectScopes: [String: Bool] = [:]
    @State private var inlineKinds: [String: RecognitionMemoryEntry.Kind] = [:]
    @State private var error: String?
    @FocusState private var focusedField: Field?

    private enum Field { case mistaken, canonical }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("纠正并学习").font(.title3.weight(.medium))
                Text("告诉应用“识别成什么、正确应是什么”。保存后会修正本次逐字稿，并用于后续会议。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            Form {
                if !uncertaintyCandidates.isEmpty {
                    Section {
                        ForEach(uncertaintyCandidates, id: \.self) { candidate in
                            HStack(spacing: 12) {
                                Text(candidate)
                                    .foregroundStyle(.primary)
                                    .frame(width: 150, alignment: .leading)
                                    .lineLimit(2)
                                Image(systemName: "arrow.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                                TextField("", text: Binding(
                                    get: { inlineCorrections[candidate] ?? "" },
                                    set: { inlineCorrections[candidate] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                Picker("", selection: Binding(
                                    get: { inlineKinds[candidate] ?? .term },
                                    set: { inlineKinds[candidate] = $0 }
                                )) {
                                    ForEach(RecognitionMemoryEntry.Kind.allCases) {
                                        Text($0.label).tag($0)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 82)
                                if workspaceID != nil {
                                    Picker("", selection: Binding(
                                        get: { inlineProjectScopes[candidate] ?? true },
                                        set: { inlineProjectScopes[candidate] = $0 }
                                    )) {
                                        Text("当前项目").tag(true)
                                        Text("所有会议").tag(false)
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(width: 105)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    } header: {
                        HStack(spacing: 12) {
                            Text("本次待确认").frame(width: 150, alignment: .leading)
                            Spacer().frame(width: 10)
                            Text("正确写法").frame(maxWidth: .infinity, alignment: .leading)
                            Text("类型").frame(width: 82)
                            if workspaceID != nil { Text("范围").frame(width: 105) }
                        }
                    }
                }
                Section("新增识别记忆") {
                    TextField("这次识别成（例如：张三峰）", text: $mistaken)
                        .focused($focusedField, equals: .mistaken)
                    TextField("正确写法（例如：张三丰）", text: $canonical)
                        .focused($focusedField, equals: .canonical)
                    Picker("类型", selection: $kind) {
                        ForEach(RecognitionMemoryEntry.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    if workspaceID != nil {
                        Toggle("仅用于当前项目", isOn: $projectOnly)
                    }
                    Button("加入") { add() }.disabled(canonical.trimmed.isEmpty)
                }
                if !saved.isEmpty {
                    Section("本次将保存") {
                        ForEach(saved) { entry in
                            HStack {
                                Text(entry.mistaken.isEmpty ? entry.canonical : "\(entry.mistaken) → \(entry.canonical)")
                                Spacer(); Text(entry.kind.label).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并重新生成纪要") { save() }
                    .buttonStyle(.borderedProminent).disabled(saved.isEmpty && inlineEntries.isEmpty)
            }.padding(14)
        }.frame(width: 760, height: 570)
    }

    private func add() {
        let correct = canonical.trimmed
        guard !correct.isEmpty else { return }
        saved.append(RecognitionMemoryEntry(
            mistaken: mistaken.trimmed, canonical: correct, kind: kind,
            workspaceID: projectOnly ? workspaceID : nil, sourceTitle: sourceTitle))
        mistaken = ""; canonical = ""
    }

    private func save() {
        do {
            for entry in saved + inlineEntries { try RecognitionMemoryStore.upsert(entry) }
            onSaved(); dismiss()
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }

    /// The model may report several uncertain names in one sentence. Present
    /// quoted values independently so the user never has to edit the prose
    /// around them before entering a correction.
    private var uncertaintyCandidates: [String] {
        RecognitionCandidateExtractor.candidates(from: uncertainties)
    }

    private var inlineEntries: [RecognitionMemoryEntry] {
        uncertaintyCandidates.compactMap { candidate in
            let correct = (inlineCorrections[candidate] ?? "").trimmed
            guard !correct.isEmpty, correct != candidate else { return nil }
            return RecognitionMemoryEntry(
                mistaken: candidate, canonical: correct,
                kind: inlineKinds[candidate] ?? .term,
                workspaceID: (inlineProjectScopes[candidate] ?? true) ? workspaceID : nil,
                sourceTitle: sourceTitle)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
