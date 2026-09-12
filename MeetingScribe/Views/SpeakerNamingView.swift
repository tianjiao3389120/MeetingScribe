import SwiftUI
import AVFoundation

/// Lets the user put names to the speakers a run separated.
///
/// Enrolling from a meeting you just processed beats recording samples up
/// front: you already know who is who, and each naming teaches the app to
/// recognise that person automatically next time.
struct SpeakerNamingView: View {
    let assets: MeetingAssets
    var onSaved: ([Int: String], [Int: SpeakerRole]) -> Void
    var onCancel: () -> Void

    @State private var names: [Int: String] = [:]
    @State private var roles: [Int: SpeakerRole] = [:]
    @State private var player: AVAudioPlayer?
    @State private var playingSpeaker: Int?
    @State private var clipURL: URL?
    @State private var playbackTask: Task<Void, Never>?
    @State private var saveError: String?
    @State private var isSaving = false

    private var diarization: Diarization? { assets.diarization }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("确认说话人姓名与角色")
                    .font(.title3.weight(.medium))
                Text("姓名用于声纹记忆；所属方和角色只用于本次会议。多个声音片段使用同一姓名时，修改其中一项会自动同步角色。无法确认的字段可以留空。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("每行代表一个独立声纹；同名通常是同一人的不同声纹片段，但请播放片段确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(groupedSpeakers, id: \.id) { entry in
                        SpeakerRow(
                            label: entry.name,
                            seconds: entry.seconds,
                            share: entry.share,
                            recognised: entry.speakers.contains { diarization?.names[$0] != nil } ? entry.name : nil,
                            sample: sampleText(for: entry.speakers.first ?? 0),
                            isPlaying: playingSpeaker == (entry.speakers.first ?? 0),
                            name: Binding(
                                get: { names[entry.speakers.first ?? 0] ?? "" },
                                set: { value in entry.speakers.forEach { names[$0] = value } }
                            ),
                            affiliation: Binding(
                                get: { roles[entry.speakers.first ?? 0]?.affiliation ?? .unknown },
                                set: { value in
                                    entry.speakers.forEach { speaker in
                                        var role = roles[speaker] ?? SpeakerRole(); role.affiliation = value
                                        roles = SpeakerRole.applying(role, to: speaker, names: names, roles: roles)
                                    }
                                }
                            ),
                            meetingRole: Binding(
                                get: { roles[entry.speakers.first ?? 0]?.meetingRole ?? .unknown },
                                set: { value in
                                    entry.speakers.forEach { speaker in
                                        var role = roles[speaker] ?? SpeakerRole(); role.meetingRole = value
                                        roles = SpeakerRole.applying(role, to: speaker, names: names, roles: roles)
                                    }
                                }
                            ),
                            onPlay: { play(speaker: entry.speakers.first ?? 0) }
                        )
                        Divider()
                    }
                }
            }

            Divider()

            HStack {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("跳过") { stop(); onCancel() }
                Button("保存并重新生成纪要") { enroll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || (names.values.allSatisfy {
                        $0.trimmingCharacters(in: .whitespaces).isEmpty
                    } && roles.values.allSatisfy { !$0.isSpecified }))
            }
            .padding(16)
        }
        .frame(width: 620, height: 520)
        .onAppear(perform: prefill)
        .onDisappear(perform: stop)
    }

    private var rankedSpeakers: [(speaker: Int, seconds: TimeInterval, share: Double)] {
        guard let diarization else { return [] }
        let total = diarization.segments.reduce(0.0) { $0 + ($1.end - $1.start) }
        return diarization.ranking.map {
            (speaker: $0.speaker, seconds: $0.seconds, share: $0.seconds / max(total, 1))
        }
    }

    private struct SpeakerGroup: Identifiable {
        let speakers: [Int]; let name: String; let seconds: TimeInterval; let share: Double
        var id: String { speakers.map(String.init).joined(separator: ",") }
    }

    private var groupedSpeakers: [SpeakerGroup] {
        let groups = Dictionary(grouping: rankedSpeakers) { entry in
            let name = names[entry.speaker] ?? diarization?.names[entry.speaker] ?? ""
            return name.isEmpty ? "#\(entry.speaker)" : name
        }
        let total = rankedSpeakers.reduce(0) { $0 + $1.seconds }
        return groups.values.map { entries in
            let speakers = entries.map(\.speaker).sorted()
            let name = names[speakers[0]] ?? diarization?.names[speakers[0]]
                ?? diarization?.labels[speakers[0]] ?? "未知"
            let seconds = entries.reduce(0) { $0 + $1.seconds }
            return SpeakerGroup(speakers: speakers, name: name, seconds: seconds, share: seconds / max(total, 1))
        }.sorted { $0.seconds > $1.seconds }
    }

    private func displayLabel(for speaker: Int) -> String {
        guard let diarization, let name = diarization.names[speaker], !name.isEmpty else {
            return diarization?.labels[speaker] ?? "\(speaker)"
        }
        let same = diarization.names.filter { $0.value == name }.map(\.key).sorted()
        guard same.count > 1, let index = same.firstIndex(of: speaker) else { return name }
        return "\(name) · 声纹\(index + 1)"
    }

    /// Seed already-recognised people so the user confirms rather than retypes.
    private func prefill() {
        guard let diarization else { return }
        for (speaker, name) in diarization.names { names[speaker] = name }
        roles = diarization.roles
    }

    /// A line this speaker actually said, to jog the user's memory.
    private func sampleText(for speaker: Int) -> String {
        guard let diarization else { return "" }
        let candidates = assets.transcript.segments.filter {
            diarization.speaker(from: $0.start, to: $0.end) == speaker && $0.text.count > 12
        }
        return candidates.max { $0.text.count < $1.text.count }?.text ?? ""
    }

    // MARK: - Playback

    /// Plays this speaker's longest turn, clipped so identifying someone takes
    /// seconds rather than sitting through a whole monologue.
    private func play(speaker: Int) {
        stop()
        guard let diarization,
              let turn = diarization.segments
                .filter({ $0.speaker == speaker })
                .max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
        else { return }

        playbackTask = Task {
            let clip = FileManager.default.temporaryDirectory
                .appendingPathComponent("meetingscribe-speaker-\(UUID().uuidString).m4a")
            clipURL = clip
            defer {
                try? FileManager.default.removeItem(at: clip)
                if clipURL == clip { clipURL = nil }
            }
            let duration = min(turn.end - turn.start, 12)
            do {
                try await MediaExtractor(url: assets.sourceURL)
                    .exportClip(from: turn.start, duration: duration, to: clip)
                let audioPlayer = try AVAudioPlayer(contentsOf: clip)
                player = audioPlayer
                playingSpeaker = speaker
                audioPlayer.play()
                try? await Task.sleep(for: .seconds(duration))
                if playingSpeaker == speaker { playingSpeaker = nil }
            } catch {
                playingSpeaker = nil
            }
        }
    }

    private func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        player?.stop()
        player = nil
        playingSpeaker = nil
        if let clipURL {
            try? FileManager.default.removeItem(at: clipURL)
            self.clipURL = nil
        }
    }

    private func enroll() {
        guard let diarization else { return }
        saveError = nil
        var applied: [Int: String] = [:]
        let entered = names.compactMap { speaker, rawName -> (Int, String)? in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : (speaker, name)
        }
        isSaving = true
        Task {
          do {
            var samples: [(name: String, embedding: [Float], note: String, referenceClipURL: URL?)] = []
            var temporaryClips: [URL] = []
            defer { temporaryClips.forEach { try? FileManager.default.removeItem(at: $0) } }
            for (speaker, name) in entered {
                guard let embedding = diarization.embeddings["\(speaker)"] else { continue }
                var reference: URL?
                if let turn = diarization.segments.filter({ $0.speaker == speaker })
                    .max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
                    let clip = FileManager.default.temporaryDirectory
                        .appendingPathComponent("meetingscribe-reference-\(UUID().uuidString).m4a")
                    try await MediaExtractor(url: assets.sourceURL)
                        .exportClip(from: turn.start, duration: min(turn.end - turn.start, 12), to: clip)
                    temporaryClips.append(clip)
                    reference = clip
                }
                samples.append((name, embedding, "", reference))
                applied[speaker] = name
            }
            if !samples.isEmpty { try VoiceProfileStore.enroll(samples: samples) }
            for (_, name) in entered {
                try RecognitionMemoryStore.upsert(RecognitionMemoryEntry(
                    canonical: name, kind: .person,
                    workspaceID: assets.workspace?.id, sourceTitle: assets.title))
            }
            stop()
            onSaved(applied, roles.filter { $0.value.isSpecified })
          } catch {
            saveError = "保存失败：\(error.localizedDescription)"
            isSaving = false
          }
        }
    }
}

private struct SpeakerRow: View {
    let label: String
    let seconds: TimeInterval
    let share: Double
    let recognised: String?
    let sample: String
    let isPlaying: Bool
    @Binding var name: String
    @Binding var affiliation: SpeakerRole.Affiliation
    @Binding var meetingRole: SpeakerRole.MeetingRole
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("播放这个人最长的一段发言")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("说话人\(label)")
                        .font(.callout.weight(.medium))
                    Text("\(TranscriptSegment.humanDuration(seconds)) · \(Int(share * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if recognised != nil {
                        Label("已识别", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                if !sample.isEmpty {
                    Text("「\(sample.prefix(48))\(sample.count > 48 ? "…" : "")」")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                HStack {
                    TextField("姓名（留空则保持匿名）", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    Picker("所属方", selection: $affiliation) {
                        ForEach(SpeakerRole.Affiliation.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 120)
                    Picker("角色", selection: $meetingRole) {
                        ForEach(SpeakerRole.MeetingRole.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 130)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
