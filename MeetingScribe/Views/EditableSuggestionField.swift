import SwiftUI

/// A compact classification picker that reveals text entry only when needed.
struct EditableSuggestionField: View {
    let title: String
    @Binding var text: String
    let suggestions: [String]
    @State private var isEnteringNewValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker(title, selection: selection) {
                Text("未知").tag("")
                ForEach(choices, id: \.self) { value in
                    Text(value).tag(value)
                }
                Divider()
                Text("新增…").tag(newValueToken)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            }
            if isEnteringNewValue {
                HStack {
                    TextField("输入新的\(shortTitle)", text: $text)
                        .textFieldStyle(.roundedBorder)
                    Button("取消") {
                        text = ""
                        isEnteringNewValue = false
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private let newValueToken = "__meeting_scribe_new_value__"

    private var shortTitle: String {
        title.components(separatedBy: "（").first ?? title
    }

    private var choices: [String] {
        let cleaned = suggestions.filter { !$0.isEmpty && $0 != text }
        return text.isEmpty || isEnteringNewValue ? cleaned : [text] + cleaned
    }

    private var selection: Binding<String> {
        Binding {
            isEnteringNewValue ? newValueToken : text
        } set: { value in
            if value == newValueToken {
                text = ""
                withAnimation { isEnteringNewValue = true }
            } else {
                text = value
                withAnimation { isEnteringNewValue = false }
            }
        }
    }
}
