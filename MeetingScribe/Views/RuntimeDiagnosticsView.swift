import AppKit
import SwiftUI

struct RuntimeDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var results = RuntimeDiagnostics.check()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("运行环境诊断").font(.title2.weight(.semibold))
                    Text("只检查本机安装与配置，不会调用模型或产生费用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新检查", systemImage: "arrow.clockwise") { results = RuntimeDiagnostics.check() }
            }
            .padding(20)

            Divider()
            List(results) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.level.symbol)
                        .foregroundStyle(color(for: item.level))
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.callout.weight(.semibold))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 520)
    }

    private func color(for level: RuntimeDiagnostic.Level) -> Color {
        switch level {
        case .ready: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}
