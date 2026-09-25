import AppKit
import SwiftUI

struct ProjectIssueAnalysisView: View {
    @Environment(\.dismiss) private var dismiss
    let issue: ProjectIssue
    let records: [MeetingRecord]
    let existingAnalysis: ProjectIssueAnalysis?
    let onSaved: (ProjectLedger) -> Void

    @State private var summary: String
    @State private var timeline: [ProjectIssueAnalysis.TimelineItem]
    @State private var analysisSnapshot: ProjectIssueAnalysis?
    @State private var overview: String
    @State private var stableConclusion: String
    @State private var latestProgress: String
    @State private var error: String?
    @State private var isAnalyzing = false
    @State private var didCopy = false
    @State private var isStarred: Bool
    // The overview is the primary reading surface. Show the complete cause-to-result
    // narrative on first open while still allowing long reports to be collapsed.
    @State private var isOverviewExpanded = true
    @State private var isLatestProgressExpanded = false
    @State private var isTimelineExpanded = false
    @State private var notice: String?

    init(issue: ProjectIssue, records: [MeetingRecord],
         existingAnalysis: ProjectIssueAnalysis?,
         onSaved: @escaping (ProjectLedger) -> Void) {
        self.issue = issue
        self.records = records
        self.existingAnalysis = existingAnalysis
        self.onSaved = onSaved
        _summary = State(initialValue: existingAnalysis?.summary
                         ?? existingAnalysis?.markdown ?? "")
        _timeline = State(initialValue: existingAnalysis?.timeline ?? [])
        _analysisSnapshot = State(initialValue: existingAnalysis)
        _overview = State(initialValue: existingAnalysis?.overview
            ?? existingAnalysis?.stableConclusion
            ?? existingAnalysis?.summary ?? "")
        _stableConclusion = State(initialValue: ProjectIssueAnalysisService
            .userFacingStableConclusion(existingAnalysis?.stableConclusion ?? ""))
        _latestProgress = State(initialValue: ProjectIssueAnalysisService
            .userFacingLatestProgress(existingAnalysis?.latestProgress ?? ""))
        _isStarred = State(initialValue: issue.isStarred)
        _notice = State(initialValue: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("问题专题分析").font(.title2.weight(.semibold))
                    Text(issue.title).font(.callout).foregroundStyle(.secondary)
                    if let generatedAt = analysisSnapshot?.generatedAt, !summary.isEmpty {
                        Text("保存于 \(generatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button {
                    toggleStar()
                } label: {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .foregroundStyle(isStarred ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(isStarred ? "取消重点问题" : "标为重点问题")
                .accessibilityLabel(isStarred ? "取消重点问题" : "标为重点问题")
                if !summary.isEmpty {
                    Button(didCopy ? "已复制" : "复制总结") { copySummary() }
                    Button("重新分析") { startAnalysis() }
                        .disabled(isAnalyzing)
                }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()

            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08))
                Divider()
            }

            if isAnalyzing && summary.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在分析 \(issue.events.count) 条已关联的问题进展…")
                        .foregroundStyle(.secondary)
                    Text("报告生成后会保存，但不会修改问题状态。")
                        .font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, summary.isEmpty {
                ContentUnavailableView {
                    Label("分析失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { startAnalysis() }
                }
            } else if summary.isEmpty {
                ContentUnavailableView {
                    Label("尚未生成问题分析", systemImage: "sparkles")
                } description: {
                    Text("将发送 \(issue.events.count) 条已确认进展，预计约 \(ProjectIssueAnalysisService.estimatedTokens(issue: issue, records: records, previousAnalysis: analysisSnapshot).formatted()) Token。")
                } actions: {
                    Button("开始分析") { startAnalysis() }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if hasStructuredProfile {
                            profileContent
                        } else {
                            Text(summary)
                                .font(.body).lineSpacing(5).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !timeline.isEmpty {
                            timelineDisclosure
                        }
                    }
                    .padding(24)
                }
                .overlay(alignment: .top) {
                    if isAnalyzing { ProgressView().padding(12) }
                }
            }
        }
        .frame(width: 880, height: 740)
    }

    private var hasStructuredProfile: Bool {
        nonempty(stableConclusion) != nil && nonempty(overview) != nil
    }

    private var profileContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("问题档案").font(.headline)
            profileCard(
                title: usesOverview ? "问题全貌" : "稳定结论",
                icon: usesOverview ? "doc.text.magnifyingglass" : "checkmark.seal.fill",
                color: .blue, text: overview,
                expanded: isOverviewExpanded) {
                    isOverviewExpanded.toggle()
                }
            if nonempty(latestProgress) != nil {
                profileCard(
                    title: "最新进展", icon: "arrow.triangle.2.circlepath",
                    color: .green, text: latestProgress,
                    expanded: isLatestProgressExpanded) {
                        isLatestProgressExpanded.toggle()
                    }
            }
        }
    }

    private var usesOverview: Bool {
        nonempty(analysisSnapshot?.overview) != nil
    }

    private func profileCard(title: String, icon: String, color: Color,
                             text: String, expanded: Bool,
                             onToggle: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.body).lineSpacing(4).textSelection(.enabled)
                    .lineLimit(expanded ? nil : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if text.count > 120 {
                    Button(expanded ? "收起" : "展开全文", action: onToggle)
                        .font(.caption).buttonStyle(.plain).foregroundStyle(color)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var timelineDisclosure: some View {
        DisclosureGroup(isExpanded: $isTimelineExpanded) {
            visualTimeline.padding(.top, 16)
        } label: {
            HStack {
                Label("完整时间线", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Text("\(timeline.count) 场会议")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var visualTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(timeline.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                        if index < timeline.count - 1 {
                            Rectangle().fill(Color.accentColor.opacity(0.3))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }
                    }.padding(.top, 5)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(item.date).font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            if let stage = nonempty(item.stage) {
                                Text(stage)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                            if let status = nonempty(item.status) {
                                Text(status).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(item.meetingTitle).font(.callout.weight(.semibold))
                        VStack(alignment: .leading, spacing: 7) {
                            timelineDetail("当时情况", value: item.situation)
                            timelineDetail("下一步", value: item.nextStep)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.bottom, index < timeline.count - 1 ? 18 : 0)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func timelineDetail(_ label: String, value: String?) -> some View {
        if let value = nonempty(value) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func startAnalysis() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        error = nil
        notice = nil
        didCopy = false
        Task {
            do {
                let related = records.first { record in
                    issue.events.contains { $0.meetingID == record.id }
                }
                let context = TokenUsageContext(
                    feature: "项目问题分析", customer: related?.customerName,
                    project: related?.projectName, meetingID: related?.id,
                    meetingTitle: issue.title)
                let report = try await TokenUsageContext.$current.withValue(context) {
                    try await ProjectIssueAnalysisService(settings: .shared)
                        .analyze(
                            issue: issue, records: records,
                            previousAnalysis: analysisSnapshot)
                }
                summary = report.summary
                overview = report.overview
                stableConclusion = report.stableConclusion
                latestProgress = report.latestProgress
                timeline = report.timeline.map {
                    .init(date: $0.date, meetingTitle: $0.meetingTitle, change: $0.change,
                          stage: $0.stage, status: $0.status, situation: $0.situation,
                          evidence: $0.evidence, nextStep: $0.nextStep)
                }
                if report.wasUpToDate {
                    notice = "当前分析已是最新，没有新增会议需要处理。"
                } else {
                    let updated = try ProjectLedgerStore.saveIssueAnalysis(
                        issue: issue, report: report)
                    analysisSnapshot = updated.analysis(for: issue.id)
                    onSaved(updated)
                }
            } catch {
                self.error = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        let value: String
        if hasStructuredProfile {
            var sections = ["\(usesOverview ? "问题全貌" : "稳定结论")：\(overview)"]
            if let progress = nonempty(latestProgress) {
                sections.append("最新进展：\(progress)")
            }
            value = sections.joined(separator: "\n\n")
        } else {
            value = summary
        }
        NSPasteboard.general.setString(value, forType: .string)
        didCopy = true
    }

    private func toggleStar() {
        do {
            let updated = try ProjectLedgerStore.setIssueStar(
                issueID: issue.id, starred: !isStarred)
            isStarred.toggle()
            onSaved(updated)
        } catch {
            self.error = "重点标记更新失败：\(error.localizedDescription)"
        }
    }
}
