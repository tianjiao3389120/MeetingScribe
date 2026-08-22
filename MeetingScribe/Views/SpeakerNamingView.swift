import SwiftUI
import AVFoundation

/// Lets the user put names to the speakers a run separated.
///
/// Enrolling from a meeting you just processed beats recording samples up
/// front: you already know who is who, and each naming teaches the app to
/// recognise that person automatically next time.
struct SpeakerNamingView: View {
    let assets: MeetingAssets
    var onSaved: ([Int: String]) -> Void
    var onCancel: () -> Void

    @State private var names: [Int: String] = [:]
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
                Text("给说话人命名")
                    .font(.title3.weight(.medium))
                Text("填写后会记住每个人的声纹，之后的会议自动识别，纪要里直接写真名。可以只填认得出的人，留空的保持匿名。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rankedSpeakers, id: \.speaker) { entry in
                        SpeakerRow(
                            label: diarization?.labels[entry.speaker] ?? "\(entry.speaker)",
                            seconds: entry.seconds,
                            share: entry.share,
                            recognised: diarization?.names[entry.speaker],
                            sample: sampleText(for: entry.speaker),
                            isPlaying: playingSpeaker == entry.speaker,
                            name: Binding(
                                get: { names[entry.speaker] ?? "" },
                                set: { names[entry.speaker] = $0 }
                            ),
                            onPlay: { play(speaker: entry.speaker) }
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
                    .disabled(isSaving || names.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
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

    /// Seed already-recognised people so the user confirms rather than retypes.
    private func prefill() {
        guard let diarization else { return }
        for (speaker, name) in diarization.names { names[speaker] = name }
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
            try VoiceProfileStore.enroll(samples: samples)
            for (_, name) in entered {
                try RecognitionMemoryStore.upsert(RecognitionMemoryEntry(
                    canonical: name, kind: .person,
                    workspaceID: assets.workspace?.id, sourceTitle: assets.title))
            }
            stop()
            onSaved(applied)
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

                TextField("姓名（留空则保持匿名）", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
