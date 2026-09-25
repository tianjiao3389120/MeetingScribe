import AppKit
import Foundation

enum MinutesDocumentOpener {
    static func open(markdown: String, title: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribe-Open", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = title.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]"#, with: "_", options: .regularExpression)
        let filename = safeTitle.isEmpty ? "会议纪要.md" : "\(safeTitle) 纪要.md"
        let url = directory.appendingPathComponent(filename)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        guard NSWorkspace.shared.open(url) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "没有找到可打开 Markdown 文件的默认应用。"
            ])
        }
    }
}
