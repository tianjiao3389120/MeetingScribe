import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

enum MaterialExtractor {
    enum Failure: LocalizedError {
        case unsupported(String), unreadable(String), noText(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let name): return "暂不支持材料格式：\(name)"
            case .unreadable(let name): return "无法读取材料：\(name)"
            case .noText(let name): return "材料中没有提取到文字：\(name)"
            }
        }
    }

    static let supportedExtensions = ["pdf", "txt", "md", "markdown", "csv", "json",
                                      "png", "jpg", "jpeg"]
    static let perFileCharacterLimit = 15_000
    static let totalCharacterLimit = 24_000
    static let maxFiles = 12

    static func extract(from url: URL) throws -> SupportingMaterial {
        let ext = url.pathExtension.lowercased()
        let kind: SupportingMaterial.Kind
        let text: String
        var imageJPEG: Data?

        switch ext {
        case "pdf":
            kind = .pdf
            guard let document = PDFDocument(url: url) else { throw Failure.unreadable(url.lastPathComponent) }
            text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
        case "txt", "md", "markdown", "csv", "json":
            kind = .text
            guard let value = try? String(contentsOf: url, encoding: .utf8) else {
                throw Failure.unreadable(url.lastPathComponent)
            }
            text = value
        case "png", "jpg", "jpeg":
            kind = .image
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw Failure.unreadable(url.lastPathComponent)
            }
            text = TextRecognizer.recognize(image).joined(separator: "\n")
            imageJPEG = jpegData(from: image)
        default:
            throw Failure.unsupported(url.lastPathComponent)
        }

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty || imageJPEG != nil else { throw Failure.noText(url.lastPathComponent) }
        return SupportingMaterial(sourceURL: url, kind: kind,
                                  extractedText: String(cleaned.prefix(perFileCharacterLimit)),
                                  imageJPEG: imageJPEG)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
