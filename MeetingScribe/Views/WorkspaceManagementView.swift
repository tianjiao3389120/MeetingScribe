import SwiftUI
import AVFoundation

struct WorkspaceManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workspaces: [MeetingWorkspace] = []
    @State private var error: String?
    @State private var originalIDs: Set<UUID> = []
    @State private var pendingDelete: MeetingWorkspace?
    @State private var voiceProfiles: [VoiceProfile] = []
    @State private var affiliations = HistoricalPersonAffiliations(records: [], workspaces: [])
    @State private var companyProfileIDs: Set<UUID> = []
    @State private var selection: SidebarSelection = .company
    @State private var player: AVAudioPlayer?
    @State private var playingProfileID: UUID?
    @State private var pendingProfileDelete: VoiceProfile?

    private enum SidebarSelection: Hashable {
        case company
        case workspace(UUID)
    }

    private var customers: [MeetingWorkspace] { workspaces.filter(\.isCustomer) }
    private var projects: [MeetingWorkspace] { workspaces.filter { !$0.isCustomer } }
    private var ourProfiles: [VoiceProfile] {
        voiceProfiles.filter { companyProfileIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("客户与项目管理").font(.title3.weight(.medium))
                    Text("统一管理客户、项目和人员资料。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("新建客户", systemImage: "person.badge.plus", action: addCustomer)
                    Button("新建项目", systemImage: "folder.badge.plus", action: addProject)
                        .disabled(customers.isEmpty)
                } label: { Label("新建", systemImage: "plus") }
            }.padding(20)
            Divider()
            HSplitView {
                List(selection: $selection) {
                    Section("我司") {
                        Label("人员（\(ourProfiles.count)）", systemImage: "building.2")
                            .tag(SidebarSelection.company)
                    }
                    Section("客户") {
                        ForEach(customers) { customer in
                            Label(customer.name, systemImage: "person.2")
                                .tag(SidebarSelection.workspace(customer.id))
                        }
                    }
                    Section("项目") {
                        ForEach(projects) { project in
                            Label(project.name, systemImage: "folder")
                                .tag(SidebarSelection.workspace(project.id))
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 250)

                ScrollView {
                    detailView
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(24)
                }
                .frame(minWidth: 500)
            }
            Divider()
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并关闭") { saveAndClose() }.keyboardShortcut(.defaultAction)
            }.padding(14)
        }
        .frame(width: 820, height: 560)
        .onAppear {
            workspaces = (try? MeetingWorkspaceStore.load()) ?? []
            voiceProfiles = VoiceProfileStore.load()
            let records = (try? MeetingHistoryStore.loadAll()) ?? []
            affiliations = HistoricalPersonAffiliations(records: records, workspaces: workspaces)
            companyProfileIDs = Set(voiceProfiles.compactMap {
                let historical = affiliations.globalAffiliation(for: $0.name)
                return historical == .ours || (historical == nil && $0.affiliation == .ours)
                    ? $0.id : nil
            })
            workspaces = CustomerContactDirectory.mergingHistoricalContacts(
                into: workspaces, records: records, affiliations: affiliations)
            originalIDs = Set(workspaces.map(\.id))
        }
        .onDisappear { player?.stop() }
        .alert("删除这个项目或会议分组？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let value = pendingDelete {
                    workspaces.removeAll { $0.id == value.id }
                    selection = .company
                }
                pendingDelete = nil
            }
        } message: {
            Text("保存后，历史会议仍保留已填写的客户、项目名称和会议类型；仅解除项目资料关联。")
        }
        .alert("删除“\(pendingProfileDelete?.name ?? "")”的声纹？",
               isPresented: Binding(
                get: { pendingProfileDelete != nil },
                set: { if !$0 { pendingProfileDelete = nil } }
               )) {
            Button("取消", role: .cancel) { pendingProfileDelete = nil }
            Button("删除声纹", role: .destructive) { removePendingProfile() }
        } message: {
            Text("保存并关闭后只删除本地声纹；不删除人员姓名、客户联系人或会议记录。")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .company:
            companyDetail
        case .workspace(let id):
            if workspaces.contains(where: { $0.id == id }) {
                workspaceDetail(workspaceBinding(for: id))
            } else {
                ContentUnavailableView("请选择客户或项目", systemImage: "sidebar.left")
            }
        }
    }

    private var companyDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            detailHeader(title: "我司", subtitle: "全局人员 · \(ourProfiles.count) 人", workspace: nil)
            Text("人员信息")
                .font(.headline)
            DisclosureGroup("我司人员（\(ourProfiles.count)）") {
                VStack(spacing: 10) {
                    ForEach(ourProfiles) { item in
                        let profile = profileBinding(for: item.id)
                        HStack(spacing: 12) {
                            voicePlaybackButton(profile.wrappedValue)
                            TextField("人员姓名", text: profile.name)
                            Spacer()
                            Text("\(profile.wrappedValue.representativeEmbeddings.count) 个代表声纹 · 已确认 \(profile.wrappedValue.sampleCount) 次")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                pendingProfileDelete = profile.wrappedValue
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("删除声纹")
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.top, 10)
            }
            Text("人员归属来自会议中的“所属方”；全局声纹只用于跨会议识别人名。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func workspaceDetail(_ workspace: Binding<MeetingWorkspace>) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            detailHeader(
                title: workspace.wrappedValue.name,
                subtitle: workspace.wrappedValue.isCustomer ? "客户资料" : "项目资料",
                workspace: workspace.wrappedValue)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text(workspace.wrappedValue.isCustomer ? "客户名称" : "项目名称")
                        .foregroundStyle(.secondary)
                    TextField(workspace.wrappedValue.isCustomer ? "客户名称" : "项目名称",
                              text: workspace.name)
                }
                if !workspace.wrappedValue.isCustomer {
                    GridRow {
                        Text("所属客户").foregroundStyle(.secondary)
                        Picker("所属客户", selection: workspace.customerID) {
                            ForEach(customers) { customer in
                                Text(customer.name).tag(Optional(customer.id))
                            }
                        }.labelsHidden()
                    }
                }
                GridRow {
                    Text("长期背景").foregroundStyle(.secondary)
                    TextField("客户身份、产品和项目目标", text: workspace.context)
                }
            }

            if workspace.wrappedValue.isCustomer {
                Divider()
                DisclosureGroup("客户联系人（\(workspace.wrappedValue.contacts.count)）") {
                    VStack(spacing: 10) {
                        ForEach(workspace.contacts) { $contact in
                            HStack(spacing: 10) {
                                if let profile = voiceProfile(
                                    named: contact.name, customerID: workspace.wrappedValue.id) {
                                    voicePlaybackButton(profile)
                                        .help("已登记声纹 · \(profile.sampleCount) 次确认")
                                } else {
                                    Image(systemName: "waveform.badge.minus")
                                        .foregroundStyle(.secondary)
                                        .help("未登记声纹")
                                }
                                TextField("姓名", text: $contact.name)
                                TextField("角色", text: $contact.role)
                                TextField("备注", text: $contact.note)
                                if let profile = voiceProfile(
                                    named: contact.name, customerID: workspace.wrappedValue.id) {
                                    Text("声纹 \(profile.sampleCount) 次")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Button(role: .destructive) {
                                    workspace.wrappedValue.contacts.removeAll { $0.id == contact.id }
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        Button("添加联系人", systemImage: "person.badge.plus") {
                            workspace.wrappedValue.contacts.append(CustomerContact())
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 10)
                }
            }
        }
    }

    private func detailHeader(title: String, subtitle: String,
                              workspace: MeetingWorkspace?) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let workspace {
                Menu {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        pendingDelete = workspace
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
            }
        }
    }

    private func normalizedPersonName(_ value: String) -> String {
        HistoricalPersonAffiliations.normalizedName(value)
    }

    private func voiceProfile(named name: String, customerID: UUID? = nil) -> VoiceProfile? {
        let key = normalizedPersonName(name)
        let named = voiceProfiles.filter { normalizedPersonName($0.name) == key }
        guard let customerID else { return named.max { $0.updatedAt < $1.updatedAt } }
        let customerWorkspaceIDs = Set(workspaces.filter {
            $0.id == customerID || (!$0.isCustomer && $0.customerID == customerID)
        }.map(\.id))
        return named.filter {
            $0.workspaceID.map(customerWorkspaceIDs.contains) == true
        }.max { $0.updatedAt < $1.updatedAt }
            ?? named.filter { !companyProfileIDs.contains($0.id) }
                .max { $0.updatedAt < $1.updatedAt }
    }

    private func voicePlaybackButton(_ profile: VoiceProfile) -> some View {
        Button { togglePlayback(profile) } label: {
            Image(systemName: playingProfileID == profile.id ? "speaker.wave.2.fill" : "play.circle")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(VoiceProfileStore.referenceClipURL(for: profile) == nil)
        .help(VoiceProfileStore.referenceClipURL(for: profile) == nil
              ? "暂无声音样本，可在会议结果页重新登记" : "试听声音")
    }

    private func togglePlayback(_ profile: VoiceProfile) {
        if playingProfileID == profile.id {
            player?.stop(); player = nil; playingProfileID = nil
            return
        }
        guard let url = VoiceProfileStore.referenceClipURL(for: profile) else { return }
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            player = audioPlayer; playingProfileID = profile.id; audioPlayer.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + audioPlayer.duration) {
                guard playingProfileID == profile.id, player === audioPlayer else { return }
                player = nil
                playingProfileID = nil
            }
        } catch {
            self.error = "播放失败：\(error.localizedDescription)"
        }
    }

    private func removePendingProfile() {
        guard let profile = pendingProfileDelete else { return }
        pendingProfileDelete = nil
        voiceProfiles.removeAll { $0.id == profile.id }
        companyProfileIDs.remove(profile.id)
        if playingProfileID == profile.id {
            player?.stop(); player = nil; playingProfileID = nil
        }
    }

    private func workspaceBinding(for id: UUID) -> Binding<MeetingWorkspace> {
        Binding {
            workspaces.first(where: { $0.id == id })!
        } set: { value in
            guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
            workspaces[index] = value
        }
    }

    private func profileBinding(for id: UUID) -> Binding<VoiceProfile> {
        Binding {
            voiceProfiles.first(where: { $0.id == id })!
        } set: { value in
            guard let index = voiceProfiles.firstIndex(where: { $0.id == id }) else { return }
            voiceProfiles[index] = value
        }
    }

    private func saveAndClose() {
        let invalid = workspaces.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !invalid else { error = "分组名称不能为空。"; return }
        do {
            workspaces = MeetingWorkspaceStore.normalizeHierarchy(workspaces)
            for index in voiceProfiles.indices {
                if companyProfileIDs.contains(voiceProfiles[index].id) {
                    voiceProfiles[index].affiliation = .ours
                } else if let historical = affiliations.globalAffiliation(for: voiceProfiles[index].name) {
                    voiceProfiles[index].affiliation = historical
                }
            }
            try MeetingWorkspaceStore.save(workspaces)
            try VoiceProfileStore.replace(voiceProfiles)
            let removedIDs = originalIDs.subtracting(workspaces.map(\.id))
            try MeetingHistoryStore.clearWorkspaceReferences(removedIDs)
            originalIDs = Set(workspaces.map(\.id))
            error = nil
            dismiss()
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }

    private func addCustomer() {
        let customer = MeetingWorkspace(name: "新客户", kind: .customer)
        workspaces.append(customer)
        selection = .workspace(customer.id)
    }

    private func addProject() {
        guard let customer = customers.first else { return }
        let project = MeetingWorkspace(name: "新项目", kind: .project, customerID: customer.id)
        workspaces.append(project)
        selection = .workspace(project.id)
    }

    private func kindBinding(for id: UUID) -> Binding<MeetingWorkspace.Kind> {
        Binding {
            workspaces.first(where: { $0.id == id })?.kind ?? .project
        } set: { kind in
            guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
            workspaces[index].kind = kind
            if kind == .customer {
                workspaces[index].customerID = nil
                workspaces[index].meetingTypes = nil
            } else if workspaces[index].customerID == nil {
                workspaces[index].customerID = customers.first(where: { $0.id != id })?.id
            }
        }
    }
}
