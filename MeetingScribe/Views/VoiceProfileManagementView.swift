import SwiftUI

/// Reviews, renames and removes locally enrolled biometric voiceprints.
struct VoiceProfileManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [VoiceProfile] = []
    @State private var pendingDelete: VoiceProfile?
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("声纹档案")
                    .font(.title3.weight(.medium))
                Text("这里只显示已确认姓名的人。请在会议结果页点击“登记/更新声纹”，试听并填写姓名；仅导入会议不会自动新增匿名档案。声纹只保存在这台 Mac。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            List {
                ForEach($profiles) { $profile in
                    HStack(spacing: 12) {
                        Image(systemName: "person.wave.2")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("姓名", text: $profile.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                            Text("\(profile.sampleCount) 个样本 · 更新于 \(profile.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            pendingDelete = profile
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除这个人的声纹")
                    }
                    .padding(.vertical, 5)
                }
            }

            Divider()

            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if saved {
                    Label("更改已保存", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并关闭") { saveAndClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 440)
        .onAppear(perform: load)
        .alert("删除“\(pendingDelete?.name ?? "")”的声纹？",
               isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
               )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) { removePending() }
        } message: {
            Text("此操作无法恢复，之后的会议将不再自动识别这个人。")
        }
    }

    private func load() {
        do {
            profiles = try VoiceProfileStore.loadChecked()
            error = nil
        } catch {
            self.error = "读取失败：\(error.localizedDescription)"
        }
    }

    private func saveAndClose() {
        do {
            try VoiceProfileStore.replace(profiles)
            profiles = try VoiceProfileStore.loadChecked()
            error = nil
            saved = true
            dismiss()
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
            saved = false
        }
    }

    private func removePending() {
        guard let profile = pendingDelete else { return }
        pendingDelete = nil
        do {
            try VoiceProfileStore.remove(id: profile.id)
            profiles.removeAll { $0.id == profile.id }
            error = nil
        } catch {
            self.error = "删除失败：\(error.localizedDescription)"
        }
    }
}
