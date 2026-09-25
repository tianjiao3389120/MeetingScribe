import Foundation
import UniformTypeIdentifiers

enum MeetingInput: Sendable {
    case media(URL)
    case externalTranscript(ExternalTranscriptPackage)

    var primaryURL: URL {
        switch self {
        case .media(let url): return url
        case .externalTranscript(let package): return package.transcriptURL
        }
    }

    var displayName: String {
        switch self {
        case .media(let url): return url.lastPathComponent
        case .externalTranscript(let package):
            var names = [package.transcriptURL.lastPathComponent]
            if let audioURL = package.audioURL { names.append(audioURL.lastPathComponent) }
            if let textURL = package.textURL { names.append(textURL.lastPathComponent) }
            return names.joined(separator: " + ")
        }
    }

    static func classify(_ urls: [URL]) throws -> MeetingInput {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard existing.count == urls.count, !existing.isEmpty else {
            throw Failure.missingFile
        }
        let srtFiles = existing.filter { $0.pathExtension.lowercased() == "srt" }
        if let srt = srtFiles.first {
            guard srtFiles.count == 1 else { throw Failure.multipleTranscripts }
            let textFiles = existing.filter { $0.pathExtension.lowercased() == "txt" }
            guard textFiles.count <= 1 else { throw Failure.multipleCompanionTexts }
            let videoFiles = existing.filter { url in
                let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                return type?.conforms(to: .movie) == true
                    || ["mov", "mp4", "mkv"].contains(url.pathExtension.lowercased())
            }
            guard videoFiles.isEmpty else { throw Failure.screenSyncPending }
            let audioFiles = existing.filter { url in
                guard url != srt, url.pathExtension.lowercased() != "txt" else { return false }
                let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                return type?.conforms(to: .audio) == true
                    || ["m4a", "mp3", "wav", "aac", "opus"].contains(url.pathExtension.lowercased())
            }
            guard audioFiles.count <= 1 else { throw Failure.multipleAudioFiles }
            let recognized = 1 + textFiles.count + audioFiles.count
            guard recognized == existing.count else {
                throw Failure.unsupported(existing.first { url in
                    url != srt && !textFiles.contains(url) && !audioFiles.contains(url)
                }?.lastPathComponent ?? "未知文件")
            }
            return .externalTranscript(try ExternalTranscriptPackage(
                transcriptURL: srt,
                textURL: textFiles.first,
                audioURL: audioFiles.first))
        }
        guard existing.count == 1 else { throw Failure.needsSRT }
        let url = existing[0]
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard type?.conforms(to: .audiovisualContent) == true else {
            throw Failure.unsupported(url.lastPathComponent)
        }
        return .media(url)
    }

    enum Failure: LocalizedError {
        case missingFile
        case needsSRT
        case multipleTranscripts
        case multipleCompanionTexts
        case multipleAudioFiles
        case screenSyncPending
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .missingFile: return "有文件不存在或已经被移动。"
            case .needsSRT: return "一次导入多个文件时必须包含一份 SRT 逐字稿。"
            case .multipleTranscripts: return "每次只能导入一份 SRT 逐字稿。"
            case .multipleCompanionTexts: return "每次只能附带一份 TXT 阅读稿。"
            case .multipleAudioFiles: return "每次只能附带一份原始音频。"
            case .screenSyncPending: return "独立屏幕录像需要先进行时间轴同步；当前版本请先导入 SRT、TXT 和原始音频。"
            case .unsupported(let name): return "“\(name)”不是支持的音频、视频或 SRT 文件。"
            }
        }
    }
}

struct ExternalTranscriptPackage: Sendable {
    let transcriptURL: URL
    let textURL: URL?
    let audioURL: URL?
    let transcript: Transcript
    let metadata: ExternalTranscriptMetadata

    init(transcriptURL: URL, textURL: URL? = nil, audioURL: URL? = nil) throws {
        let srt = try String(contentsOf: transcriptURL, encoding: .utf8)
        let parsed = Transcript.parse(srt: srt)
        guard !parsed.segments.isEmpty else { throw Failure.emptyTranscript }
        self.transcriptURL = transcriptURL
        self.textURL = textURL
        self.audioURL = audioURL
        transcript = parsed
        if let textURL {
            do {
                let text = try String(contentsOf: textURL, encoding: .utf8)
                metadata = ExternalTranscriptMetadata.parseMiaojii(text)
            } catch {
                throw Failure.unreadableCompanionText(textURL.lastPathComponent)
            }
        } else {
            metadata = ExternalTranscriptMetadata()
        }
    }

    enum Failure: LocalizedError {
        case emptyTranscript
        case unreadableCompanionText(String)
        var errorDescription: String? {
            switch self {
            case .emptyTranscript: return "SRT 中没有找到有效的字幕时间段。"
            case .unreadableCompanionText(let name):
                return "无法读取配套 TXT“\(name)”，请确认文件使用 UTF-8 编码。"
            }
        }
    }
}

struct ExternalTranscriptMetadata: Sendable, Equatable {
    var recordedAt: Date?
    var declaredDuration: TimeInterval?
    var keywords: [String] = []

    static func parseMiaojii(_ text: String) -> ExternalTranscriptMetadata {
        var result = ExternalTranscriptMetadata()
        let lines = text.components(separatedBy: .newlines)
        if let header = lines.first, let separator = header.firstIndex(of: "|") {
            let dateText = String(header[..<separator]).trimmingCharacters(in: .whitespaces)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy年M月d日 a h:mm"
            result.recordedAt = formatter.date(from: dateText)
            let durationText = String(header[header.index(after: separator)...])
            result.declaredDuration = parseChineseDuration(durationText)
        }
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "关键词:" }),
           lines.indices.contains(index + 1) {
            result.keywords = lines[index + 1]
                .components(separatedBy: CharacterSet(charactersIn: "、,"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return result
    }

    private static func parseChineseDuration(_ raw: String) -> TimeInterval? {
        let pattern = #"(?:(\d+)小时)?\s*(?:(\d+)分钟)?\s*(?:(\d+)秒)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw))
        else { return nil }
        func value(_ group: Int) -> Double {
            let range = match.range(at: group)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: raw) else { return 0 }
            return Double(raw[swiftRange]) ?? 0
        }
        let duration = value(1) * 3600 + value(2) * 60 + value(3)
        return duration > 0 ? duration : nil
    }
}
