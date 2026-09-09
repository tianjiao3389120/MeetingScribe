import SwiftUI

struct MeetingFeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID
    let title: String
    var onRegenerate: ((String) -> Void)?

    @State private var rating: MeetingFeedback.Rating = .accurate
    @State private var issues: Set<MeetingFeedback.Issue> = []
    @State private var notes = ""
    @State private var candidateTerms = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("这份纪要怎么样？") {
                    Picker("评价", selection: $rating) {
                        ForEach(MeetingFeedback.Rating.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                    if rating == .needsImprovement {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 8)], spacing: 8) {
                            ForEach(MeetingFeedback.Issue.allCases) { issue in
                                Toggle(issue.label, isOn: Binding(
                                    get: { issues.contains(issue) },
                                    set: { selected in
                                        if selected { issues.insert(issue) }
                                        else { issues.remove(issue) }
                                    }
                                )).toggleStyle(.button)
                            }
                        }
                    }
                    TextEditor(text: $notes).frame(height: 80)
                        .overlay(alignment: .topLeading) {
                            if notes.isEmpty { Text("具体哪里需要改进（可选）").foregroundStyle(.tertiary).padding(5) }
                        }
                }
                Section("建议术语（可选）") {
                    TextField("每行一个，例如客户名、产品名或缩写", text: $candidateTerms, axis: .vertical)
                    Text("这里只加入待审核列表，不会直接修改全局词表。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("取消") { dismiss() }
                if rating == .needsImprovement, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   onRegenerate != nil {
                    Button("保存并重新生成") { save(regenerate: true) }
                }
                Button("保存反馈") { save(regenerate: false) }.keyboardShortcut(.defaultAction)
            }.padding(14)
        }
        .frame(width: 520, height: 430)
        .onAppear {
            if let existing = FeedbackStore.load(meetingID: meetingID) {
                rating = existing.rating; issues = Set(existing.issues); notes = existing.notes
            }
        }
    }

    private func save(regenerate: Bool) {
        do {
            try FeedbackStore.save(MeetingFeedback(
                meetingID: meetingID, rating: rating,
                issues: issues.sorted { $0.rawValue < $1.rawValue },
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)))
            let terms = candidateTerms.split(whereSeparator: { $0.isNewline }).map(String.init)
            try FeedbackStore.addCandidates(terms, meetingID: meetingID, title: title)
            let request = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            dismiss()
            if regenerate { onRegenerate?(request) }
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
}
