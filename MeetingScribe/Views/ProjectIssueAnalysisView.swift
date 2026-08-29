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
    @State private var error: String?
    @State private var isAnalyzing = false
    @State private var didCopy = false

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
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("问题专题分析").font(.title2.weight(.semibold))
                    Text(issue.title).font(.callout).foregroundStyle(.secondary)
                    if let generatedAt = existingAnalysis?.generatedAt, !summary.isEmpty {
                        Text("保存于 \(generatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if !summary.isEmpty {
                    Button(didCopy ? "已复制" : "复制总结") { copySummary() }
                    Button("重新分析") { startAnalysis() }
                        .disabled(isAnalyzing)
                }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()

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
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(summary)
                            .font(.body).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !timeline.isEmpty {
                            Divider()
                            Text("时间线").font(.headline)
                            visualTimeline
                        }
                    }
                    .padding(24)
                }
                .overlay(alignment: .top) {
                    if isAnalyzing { ProgressView().padding(12) }
                }
            }
        }
        .frame(width: 820, height: 700)
        .task { if summary.isEmpty { startAnalysis() } }
    }

    private var visualTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(timeline.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                        if index < timeline.count - 1 {
                            Rectangle().fill(Color.accentColor.opacity(0.3))
                                .frame(width: 2, height: 66)
                        }
                    }.padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.date).font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(item.meetingTitle).font(.caption).foregroundStyle(.secondary)
                        Text(item.change).font(.callout.weight(.semibold))
                            .textSelection(.enabled)
                    }
                    .padding(.bottom, index < timeline.count - 1 ? 18 : 0)
                    Spacer()
                }
            }
        }
    }

    private func startAnalysis() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        error = nil
        didCopy = false
        Task {
            do {
                let report = try await ProjectIssueAnalysisService(settings: .shared)
                    .analyze(issue: issue, records: records)
                let updated = try ProjectLedgerStore.saveIssueAnalysis(
                    issue: issue, report: report)
                summary = report.summary
                timeline = report.timeline.map {
                    .init(date: $0.date, meetingTitle: $0.meetingTitle, change: $0.change)
                }
                onSaved(updated)
            } catch {
                self.error = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        didCopy = true
    }
}
