import CryptoKit
import Foundation

enum RecognitionModelPackage {
    struct Manifest: Codable {
        struct FileEntry: Codable {
            let name: String
            let bytes: Int64
            let sha256: String
        }
        let formatVersion: Int
        let createdAt: Date
        let files: [FileEntry]
    }

    enum Failure: LocalizedError {
        case modelsMissing, invalidPackage, unsupportedVersion, damagedFile(String), archiveFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelsMissing: return "本机识别模型尚未完整安装，无法导出。"
            case .invalidPackage: return "这不是有效的 MeetingScribe 识别模型包。"
            case .unsupportedVersion: return "识别模型包版本过新，请升级 MeetingScribe。"
            case .damagedFile(let name): return "模型文件损坏或不完整：\(name)"
            case .archiveFailed(let message): return "模型包处理失败：\(message)"
            }
        }
    }

    private static let manifestName = "manifest.json"
    private struct FileSpec {
        let name: String
        let source: URL
        let destination: URL
        let required: Bool
    }
    private static var fileSpecs: [FileSpec] {
        [
            .init(name: ToolLocator.transcriptionModel,
                  source: ToolLocator.modelDirectory.appendingPathComponent(ToolLocator.transcriptionModel),
                  destination: ToolLocator.modelDirectory.appendingPathComponent(ToolLocator.transcriptionModel),
                  required: true),
            .init(name: ToolLocator.vadModel,
                  source: ToolLocator.modelDirectory.appendingPathComponent(ToolLocator.vadModel),
                  destination: ToolLocator.modelDirectory.appendingPathComponent(ToolLocator.vadModel),
                  required: true),
            .init(name: "speaker/segmentation-model.int8.onnx",
                  source: Diarizer.modelDirectory.appendingPathComponent(Diarizer.segmentationModel),
                  destination: Diarizer.modelDirectory.appendingPathComponent(Diarizer.segmentationModel),
                  required: false),
            .init(name: "speaker/\(Diarizer.embeddingModel)",
                  source: Diarizer.modelDirectory.appendingPathComponent(Diarizer.embeddingModel),
                  destination: Diarizer.modelDirectory.appendingPathComponent(Diarizer.embeddingModel),
                  required: false),
        ]
    }

    static func export(to destination: URL) throws {
        let manager = FileManager.default
        let stagingRoot = manager.temporaryDirectory
            .appendingPathComponent("MeetingScribe-model-export-\(UUID().uuidString)")
        let package = stagingRoot.appendingPathComponent("MeetingScribe识别模型", isDirectory: true)
        defer { try? manager.removeItem(at: stagingRoot) }
        try manager.createDirectory(at: package, withIntermediateDirectories: true)

        var entries: [Manifest.FileEntry] = []
        for spec in fileSpecs {
            guard manager.fileExists(atPath: spec.source.path) else {
                if spec.required { throw Failure.modelsMissing }
                continue
            }
            let attributes = try manager.attributesOfItem(atPath: spec.source.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0 else { throw Failure.damagedFile(spec.name) }
            let packagedFile = package.appendingPathComponent(spec.name)
            try manager.createDirectory(at: packagedFile.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            try manager.copyItem(at: spec.source, to: packagedFile)
            entries.append(.init(name: spec.name, bytes: bytes,
                                 sha256: try sha256(of: spec.source)))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Manifest(formatVersion: 2, createdAt: Date(), files: entries))
            .write(to: package.appendingPathComponent(manifestName), options: .atomic)
        try? manager.removeItem(at: destination)
        try runDitto(["-c", "-k", "--keepParent", package.path, destination.path])
    }

    static func importPackage(from archive: URL) throws {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("MeetingScribe-model-import-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try runDitto(["-x", "-k", archive.path, staging.path])
        guard let manifestURL = manager.enumerator(at: staging,
                                                   includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == manifestName }) else {
            throw Failure.invalidPackage
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion == 1 || manifest.formatVersion == 2 else {
            throw Failure.unsupportedVersion
        }
        let directory = manifestURL.deletingLastPathComponent()
        for entry in manifest.files {
            guard fileSpecs.contains(where: { $0.name == entry.name }) else { continue }
            let source = directory.appendingPathComponent(entry.name)
            let attributes = try manager.attributesOfItem(atPath: source.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes == entry.bytes, try sha256(of: source) == entry.sha256 else {
                throw Failure.damagedFile(entry.name)
            }
        }
        for spec in fileSpecs where spec.required {
            guard manifest.files.contains(where: { $0.name == spec.name }) else {
                throw Failure.invalidPackage
            }
        }

        for spec in fileSpecs where manifest.files.contains(where: { $0.name == spec.name }) {
            let source = directory.appendingPathComponent(spec.name)
            try manager.createDirectory(at: spec.destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            let temporary = spec.destination.deletingLastPathComponent()
                .appendingPathComponent(".\(spec.destination.lastPathComponent).importing")
            try? manager.removeItem(at: temporary)
            try manager.copyItem(at: source, to: temporary)
            try? manager.removeItem(at: spec.destination)
            try manager.moveItem(at: temporary, to: spec.destination)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errorPipe = Pipe(); process.standardError = errorPipe
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
            throw Failure.archiveFailed(message)
        }
    }
}
