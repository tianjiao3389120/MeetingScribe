import SwiftUI

struct TagInputView: View {
    @Binding var text: String
    let suggestions: [String]
    var placeholder = "标签，用逗号分隔"
    var showsSuggestionsWhenUnfocused = false

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            if (focused || showsSuggestionsWhenUnfocused) && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("选择已有标签")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(suggestions, id: \.self) { tag in
                                let selected = MeetingTags.contains(tag, in: text)
                                Button {
                                    text = MeetingTags.toggling(tag, in: text)
                                } label: {
                                    Label(tag, systemImage: selected ? "checkmark" : "tag")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(selected ? Color.accentColor.opacity(0.18)
                                                             : Color.secondary.opacity(0.10),
                                                    in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}
