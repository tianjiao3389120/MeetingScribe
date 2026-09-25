import SwiftUI
import AVFoundation

/// Lets the user put names to the speakers a run separated.
///
/// Enrolling from a meeting you just processed beats recording samples up
/// front: you already know who is who, and each naming teaches the app to
/// recognise that person automatically next time.
struct SpeakerNamingView: View {
    let assets: MeetingAssets
    var onSaved: ([Int: String], [Int: SpeakerRole], _ regenerateCurrentMinutes: Bool) -> Void
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
                Text("姓名用于声纹记忆；所属方决定我司全局或客户范围匹配，角色用于本次会议。多个声音片段使用同一姓名时，修改其中一项会自动同步角色。无法确认的字段可以留空。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("每行代表一个独立声纹；同名通常是同一人的不同声纹片段，但请播放片段确认。")
                    .font(.caption).foregroundStyle(.secondary)
                if let warning = diarization?.fragmentationWarning {
                    Label(warning, systemImage: "person.2.badge.gearshape")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                            suggestion: suggestion(for: entry),
                            embeddingQuality: embeddingQuality(for: entry),
                            sample: sampleText(for: entry.speakers),
                            canPlay: referenceSegment(for: entry.speakers) != nil,
                            isPlaying: playingSpeaker.map(entry.speakers.contains) == true,
                            name: Binding(
                                get: { names[entry.speakers.first ?? 0] ?? "" },
                                set: { value in applyName(value, to: entry.speakers) }
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
                            onPlay: { play(speakers: entry.speakers) },
                            onUseSuggestion: {
                                guard let suggestion = suggestion(for: entry) else { return }
                                applyName(suggestion.name, to: entry.speakers)
                            }
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
                Button("保存并重新生成纪要") { enroll(regenerate: true) }
                    .disabled(isSaving || !hasEdits)
                Button("仅保存，后续会议生效") { enroll(regenerate: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || !hasEdits)
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
        let similarityRoots = Dictionary(uniqueKeysWithValues:
            (diarization?.conservativeClusterGroups() ?? []).flatMap { group in
                group.map { ($0, group.min() ?? $0) }
            })
        let groups = Dictionary(grouping: rankedSpeakers) { entry in
            let name = names[entry.speaker] ?? diarization?.names[entry.speaker] ?? ""
            if !name.isEmpty {
                return "name:\(HistoricalPersonAffiliations.normalizedName(name))"
            }
            return "voice:\(similarityRoots[entry.speaker] ?? entry.speaker)"
        }
        let total = rankedSpeakers.reduce(0) { $0 + $1.seconds }
        return groups.values.map { entries in
            let speakers = entries.map(\.speaker).sorted()
            let confirmedName = speakers.compactMap {
                names[$0] ?? diarization?.names[$0]
            }.first { !$0.isEmpty }
            var name = confirmedName ?? diarization?.labels[speakers[0]] ?? "未知"
            if confirmedName == nil, speakers.count > 1 {
                name += " · \(speakers.count) 个相似声纹"
            }
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

    private func suggestion(for group: SpeakerGroup) -> VoiceMatchSuggestion? {
        guard let diarization else { return nil }
        return group.speakers.compactMap { diarization.nameSuggestions[$0] }
            .max { $0.score < $1.score }
    }

    private func embeddingQuality(for group: SpeakerGroup) -> VoiceEmbeddingQuality? {
        guard let diarization else { return nil }
        return group.speakers.compactMap { diarization.embeddingQualities["\($0)"] }
            .max { $0.score < $1.score }
    }

    /// Seed already-recognised people so the user confirms rather than retypes.
    private func prefill() {
        guard let diarization else { return }
        for (speaker, name) in diarization.names { names[speaker] = name }
        roles = PersonRoleDirectory.defaults(
            names: diarization.names, workspace: assets.workspace)
        roles.merge(diarization.roles) { _, meetingOverride in meetingOverride }
    }

    /// Typing or accepting an existing person immediately restores their
    /// directory affiliation and role. Explicit choices already made in this
    /// meeting remain authoritative.
    private func applyName(_ value: String, to speakers: [Int]) {
        speakers.forEach { names[$0] = value }
        let defaults = PersonRoleDirectory.defaults(
            names: Dictionary(uniqueKeysWithValues: speakers.map { ($0, value) }),
            workspace: assets.workspace)
        for speaker in speakers {
            guard let suggested = defaults[speaker] else { continue }
            var current = roles[speaker] ?? SpeakerRole()
            if current.affiliation == .unknown { current.affiliation = suggested.affiliation }
            if current.meetingRole == .unknown { current.meetingRole = suggested.meetingRole }
            roles[speaker] = current
        }
    }

    private var hasEdits: Bool {
        !names.values.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        } || roles.values.contains { $0.isSpecified }
    }

    /// A line this speaker actually said, to jog the user's memory.
    private func sampleText(for speakers: [Int]) -> String {
        guard let diarization else { return "" }
        let target = Set(speakers)
        let candidates = assets.transcript.segments.filter {
            guard let speaker = diarization.speaker(from: $0.start, to: $0.end) else { return false }
            return target.contains(speaker) && $0.text.count > 12
        }
        return candidates.max { $0.text.count < $1.text.count }?.text ?? ""
    }

    // MARK: - Playback

    /// Plays this speaker's longest turn, clipped so identifying someone takes
    /// seconds rather than sitting through a whole monologue.
    private func play(speakers: [Int]) {
        stop()
        guard let selected = referenceSegment(for: speakers) else { return }
        let speaker = selected.speaker
        let turn = selected.segment

        playbackTask = Task {
            let clip = FileManager.default.temporaryDirectory
                .appendingPathComponent("meetingscribe-speaker-\(UUID().uuidString).m4a")
            clipURL = clip
            defer {
                try? FileManager.default.removeItem(at: clip)
                if clipURL == clip { clipURL = nil }
            }
            let duration = min(turn.duration, 8)
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

    private func referenceSegment(for speakers: [Int], enrollmentOnly: Bool = false)
        -> (speaker: Int, segment: VoiceReferenceSegment)? {
        guard let diarization else { return nil }
        return speakers.compactMap { speaker -> (Int, VoiceReferenceSegment)? in
            guard let segment = diarization.referenceSegments["\(speaker)"],
                  segment.isClean,
                  !enrollmentOnly || segment.isEnrollmentReady else { return nil }
            return (speaker, segment)
        }.max { $0.1.quality < $1.1.quality }
    }

    private func enroll(regenerate: Bool) {
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
            var samples: [VoiceProfileStore.EnrollmentSample] = []
            var temporaryClips: [URL] = []
            defer { temporaryClips.forEach { try? FileManager.default.removeItem(at: $0) } }
            for (speaker, name) in entered {
                applied[speaker] = name
                guard let embedding = diarization.embeddings["\(speaker)"],
                      let referenceSegment = referenceSegment(
                        for: [speaker], enrollmentOnly: true)?.segment else { continue }
                var reference: URL?
                let clip = FileManager.default.temporaryDirectory
                    .appendingPathComponent("meetingscribe-reference-\(UUID().uuidString).m4a")
                try await MediaExtractor(url: assets.sourceURL)
                    .exportClip(from: referenceSegment.start,
                                duration: min(referenceSegment.duration, 8), to: clip)
                temporaryClips.append(clip)
                reference = clip
                let affiliation = roles[speaker]?.affiliation ?? .unknown
                let scope: UUID?
                switch affiliation {
                case .ours:
                    scope = nil
                case .customer:
                    scope = assets.workspace?.isCustomer == true
                        ? assets.workspace?.id : assets.workspace?.customerID ?? assets.workspace?.id
                case .thirdParty, .unknown:
                    scope = assets.workspace?.id
                }
                samples.append(VoiceProfileStore.EnrollmentSample(
                    name: name, embedding: embedding, note: "", referenceClipURL: reference,
                    workspaceID: scope, affiliation: affiliation == .unknown ? nil : affiliation,
                    meetingRole: roles[speaker]?.meetingRole ?? .unknown,
                    quality: min(diarization.embeddingQualities["\(speaker)"]?.score ?? 1,
                                 referenceSegment.quality)))
            }
            if !samples.isEmpty { try VoiceProfileStore.enroll(samples) }
            try? VoiceRecognitionMetricsStore.record(
                diarization: diarization, confirmedNames: applied)
            for (speaker, name) in entered {
                let affiliation = roles[speaker]?.affiliation ?? .unknown
                let scope: UUID?
                switch affiliation {
                case .ours: scope = nil
                case .customer:
                    scope = assets.workspace?.isCustomer == true
                        ? assets.workspace?.id : assets.workspace?.customerID ?? assets.workspace?.id
                case .thirdParty, .unknown: scope = assets.workspace?.id
                }
                try RecognitionMemoryStore.upsert(RecognitionMemoryEntry(
                    canonical: name, kind: .person,
                    workspaceID: scope, sourceTitle: assets.title))
            }
            syncCustomerContacts(workspaceID: assets.workspace?.id, names: applied, roles: roles)
            stop()
            onSaved(applied, roles.filter { $0.value.isSpecified }, regenerate)
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
    let suggestion: VoiceMatchSuggestion?
    let embeddingQuality: VoiceEmbeddingQuality?
    let sample: String
    let canPlay: Bool
    let isPlaying: Bool
    @Binding var name: String
    @Binding var affiliation: SpeakerRole.Affiliation
    @Binding var meetingRole: SpeakerRole.MeetingRole
    let onPlay: () -> Void
    let onUseSuggestion: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .help(canPlay ? "播放质量最高且没有重叠说话的片段" : "没有足够干净的试听片段")

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
                    if let suggestion, recognised == nil {
                        Button(action: onUseSuggestion) {
                            Text("候选：\(suggestion.name) · 匹配分 \(suggestion.score, format: .number.precision(.fractionLength(2)))")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                        .help("置信度不足以自动确认；点击填入后请试听核实")
                    }
                    if let embeddingQuality,
                       embeddingQuality.score < VoiceProfileStore.minimumEmbeddingQuality {
                        Label("样本质量不足，仅保存姓名和角色", systemImage: "waveform.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
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
