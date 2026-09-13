import SwiftUI
import AVFoundation

/// Reviews, renames and removes locally enrolled biometric voiceprints.
struct VoiceProfileManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [VoiceProfile] = []
    @State private var pendingDelete: VoiceProfile?
    @State private var error: String?
    @State private var saved = false
    @State private var player: AVAudioPlayer?
    @State private var playingID: UUID?

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
                        Button { togglePlayback(profile) } label: {
                            Image(systemName: playingID == profile.id ? "speaker.wave.2.fill" : "play.circle")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .disabled(VoiceProfileStore.referenceClipURL(for: profile) == nil)
                        .help(VoiceProfileStore.referenceClipURL(for: profile) == nil
                              ? "旧声纹暂无声音样本，可在会议结果页重新登记" : "播放经典声音")
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("姓名", text: $profile.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                            Text("\(profile.sampleCount) 次确认 · \(profile.representativeEmbeddings.count) 个代表声纹 · 更新于 \(profile.updatedAt.formatted(date: .abbreviated, time: .omitted))")
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
        .onDisappear { player?.stop() }
        .alert("删除“\(pendingDelete?.name ?? "")”的声纹？",
               isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
               )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) { removePending() }
        } message: {
            Text("保存并关闭后才会删除；在此之前可点击页面底部的“取消”撤销。")
        }
    }

    private func togglePlayback(_ profile: VoiceProfile) {
        if playingID == profile.id {
            player?.stop(); player = nil; playingID = nil
            return
        }
        guard let url = VoiceProfileStore.referenceClipURL(for: profile) else { return }
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            player = audioPlayer; playingID = profile.id; audioPlayer.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + audioPlayer.duration) {
                guard playingID == profile.id, player === audioPlayer else { return }
                player = nil
                playingID = nil
            }
        } catch {
            self.error = "播放失败：\(error.localizedDescription)"
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
        profiles.removeAll { $0.id == profile.id }
        if playingID == profile.id {
            player?.stop(); player = nil; playingID = nil
        }
        error = nil
    }
}
