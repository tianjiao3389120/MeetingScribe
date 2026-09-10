import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Turns the assembled timeline into a meeting summary.
///
/// Supports local subscription-backed CLIs and remote model APIs. The same
/// prompt is used for each backend so output remains comparable.
struct Analyzer {

    struct Result: Sendable {
        let markdown: String
        let structured: StructuredMinutes?
        /// Raw model output is retained when JSON parsing failed, so a useful
        /// legacy Markdown response is never discarded.
        let usedFallback: Bool
        let usage: GenerationUsage
    }

    let assets: MeetingAssets
    let settings: Settings

    private func prepareRequest() -> (modelAssets: MeetingAssets, imageIDs: Set<Int>, timeline: String) {
        let canSendImages: Bool
        switch settings.backend {
        case .codexCLI: canSendImages = true
        case .claudeCLI: canSendImages = false
        case .openAICompatible: canSendImages = settings.providerSupportsVision
        }
        let selectedAdaptiveIDs = canSendImages
            ? Self.selectVisualEvidenceCaptures(from: assets.captures, limit: 6)
            : Self.selectAdaptiveOCRCaptures(from: assets.captures, limit: 6)
        var modelAssets = assets
        modelAssets.captures = canSendImages
            ? assets.captures.filter { selectedAdaptiveIDs.contains($0.id) }
            : assets.captures.filter { $0.evidenceReason == nil || selectedAdaptiveIDs.contains($0.id) }
        let imageIDs = canSendImages ? selectedAdaptiveIDs : []
        let combinedContext = [modelAssets.recognitionScenario.analysisGuidance,
                               modelAssets.workspace?.context ?? "",
                               modelAssets.meetingContext,
                               IssueTracking.promptContext(for: modelAssets.workspace?.id),
                               "纪要模板（\(MinutesTemplate.template(id: modelAssets.minutesTemplateID).name)）：\(MinutesTemplate.template(id: modelAssets.minutesTemplateID).instructions)",
                               "本次纪要附加要求：\(settings.minutesInstructions)"]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        let timeline = PromptBuilder(assets: modelAssets,
                                     contextHint: combinedContext,
                                     imageCaptureIDs: imageIDs).buildTimeline()
        return (modelAssets, imageIDs, timeline)
    }

    func run(progress: @escaping @Sendable (String) -> Void) async throws -> Result {
        let prepared = prepareRequest()
        let modelAssets = prepared.modelAssets
        let imageIDs = prepared.imageIDs
        let timeline = prepared.timeline
        let debug = PipelineDebugRegistry.active
        var imageFiles: [String] = []
        var imageURLs: [URL] = []
        let temporaryImageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingscribe-model-images-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryImageDirectory) }
        for capture in modelAssets.captures where imageIDs.contains(capture.id) {
            guard let data = jpegData(from: capture.image, quality: 0.9) else { continue }
            let time = capture.timecode.replacingOccurrences(of: ":", with: "-")
            let name = "model-image-\(capture.id)-\(time).jpg"
            let url: URL?
            if let debug {
                url = debug.writeData(name, data)
            } else {
                try? FileManager.default.createDirectory(
                    at: temporaryImageDirectory, withIntermediateDirectories: true)
                let candidate = temporaryImageDirectory.appendingPathComponent(name)
                url = (try? data.write(to: candidate, options: .atomic)).map { candidate }
            }
            if let url {
                imageURLs.append(url)
                imageFiles.append("\(url.path)（\(capture.image.width)x\(capture.image.height)）")
            }
        }
        if let debug {
            let selectedReasons = Set(assets.captures.filter { imageIDs.contains($0.id) }
                .compactMap(\.evidenceReason))
            let lines = assets.captures.filter { $0.evidenceReason != nil }.map { capture in
                let decision: String
                if imageIDs.contains(capture.id) {
                    decision = "发送：\(capture.image.width)x\(capture.image.height)"
                } else if selectedReasons.contains(capture.evidenceReason ?? "") {
                    decision = "剔除：同一事件已有更优画面"
                } else {
                    decision = "剔除：超过最多 6 个事件或与其他事件重复"
                }
                return "#\(capture.id) · \(capture.timecode) · \(capture.evidenceReason ?? "<无原因>") · \(decision)"
            }
            debug.imageSelection("最终模型图片：\n" + (lines.isEmpty ? "<空>" : lines.joined(separator: "\n")))
        }
        try await debug?.beginNode("模型调用", input: """
        后端：\(settings.backend.displayName)
        模型：\(settings.backend == .openAICompatible ? settings.providerModel : "本地 CLI")
        系统提示词：
        \(PromptBuilder.systemPrompt)

        用户输入：
        \(timeline)

        模型图片：
        \(imageFiles.isEmpty ? "<空>" : imageFiles.joined(separator: "\n"))
        """)
        let report: @Sendable (String) -> Void = { message in
            debug?.progress("模型调用", message)
            progress(message)
        }
        let heartbeat = Task {
            var waited = 0
            while !Task.isCancelled {
                let interval = waited < 30 ? 10 : 30
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                waited += interval
                if !Task.isCancelled {
                    debug?.progress("模型调用", "模型仍在运行，已等待 \(waited / 60):\(String(format: "%02d", waited % 60))")
                }
            }
        }
        defer { heartbeat.cancel() }

        let raw: String
        do {
            switch settings.backend {
            case .codexCLI:
                report("正在通过本机 Codex CLI 生成纪要…")
                raw = try await runLocalCLI(timeline: timeline, imageURLs: imageURLs)
            case .claudeCLI:
                report("正在通过本机 Claude Code 生成纪要…")
                raw = try await runLocalCLI(timeline: timeline, imageURLs: [])
            case .openAICompatible:
                let preset = settings.provider
                report("正在调用 \(preset.name)（\(settings.providerModel)）生成纪要…")
                raw = try await runOpenAICompatible(timeline: timeline,
                                                    imageIDs: imageIDs,
                                                    progress: report)
            }
            debug?.endNode("模型调用", output: raw)
        } catch {
            debug?.endNode("模型调用", output: "失败：\(error.localizedDescription)")
            throw error
        }
        heartbeat.cancel()

        let phases = [GenerationUsage.estimatedPhase(
            name: "主纪要", input: PromptBuilder.systemPrompt + "\n" + timeline, output: raw)]
        if let structured = Self.parseStructured(raw) {
            return Result(markdown: StructuredMinutesRenderer.markdown(from: structured),
                          structured: structured, usedFallback: false,
                          usage: GenerationUsage(phases: phases, isEstimated: true))
        }
        return Result(markdown: raw, structured: nil, usedFallback: true,
                      usage: GenerationUsage(phases: phases, isEstimated: true))
    }

    /// IDs of adaptive frames that survive backend capability filtering and
    /// therefore appear in the model request, either as pixels or OCR text.
    static func screenFramesSentToModel(assets: MeetingAssets, settings: Settings) -> Set<Int> {
        let selected = selectAdaptiveOCRCaptures(from: assets.captures, limit: 6)
        let adaptive = assets.captures.filter {
            $0.evidenceReason != nil && selected.contains($0.id)
        }
        switch settings.backend {
        case .codexCLI:
            return selectVisualEvidenceCaptures(from: assets.captures, limit: 6)
        case .claudeCLI:
            return Set(adaptive.filter { !$0.recognizedText.isEmpty }.map(\.id))
        case .openAICompatible:
            guard settings.providerSupportsVision else {
                return Set(adaptive.filter { !$0.recognizedText.isEmpty }.map(\.id))
            }
            return selectVisualEvidenceCaptures(from: assets.captures, limit: 6)
        }
    }

    /// Select one information-rich view around each event rather than sending
    /// the before/at/after probe triplet. Eight seconds of separation folds a
    /// single requested node while still allowing nearby, distinct events.
    static func selectAdaptiveOCRCaptures(from captures: [ScreenCapture],
                                          limit: Int) -> Set<Int> {
        guard limit > 0 else { return [] }
        let ranked = captures.filter {
            $0.evidenceReason != nil && !$0.recognizedText.isEmpty
        }.sorted {
            let lhs = $0.textBlock.count + $0.recognizedText.count * 40
            let rhs = $1.textBlock.count + $1.recognizedText.count * 40
            return lhs == rhs ? $0.time < $1.time : lhs > rhs
        }
        var selected: [ScreenCapture] = []
        for capture in ranked {
            guard !selected.contains(where: { abs($0.time - capture.time) <= 8 }) else { continue }
            selected.append(capture)
            if selected.count == limit { break }
        }
        return Set(selected.map(\.id))
    }

    /// Picks one high-quality frame per transcript-selected event. OCR contributes only to
    /// ranking; selected evidence reaches a vision backend as pixels, without duplicate OCR.
    static func selectVisualEvidenceCaptures(from captures: [ScreenCapture],
                                             limit: Int) -> Set<Int> {
        guard limit > 0 else { return [] }
        let candidates = captures.filter { $0.evidenceReason != nil }
        let grouped = Dictionary(grouping: candidates) {
            $0.evidenceReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let bestPerEvent = grouped.values.compactMap { group -> ScreenCapture? in
            group.max {
                let lhs = $0.image.width * $0.image.height + $0.textBlock.count * 100
                let rhs = $1.image.width * $1.image.height + $1.textBlock.count * 100
                if lhs != rhs { return lhs < rhs }
                // Prefer the middle probe when visual/text quality ties.
                let middle = group.map(\.time).reduce(0, +) / Double(group.count)
                return abs($0.time - middle) > abs($1.time - middle)
            }
        }
        return Set(bestPerEvent.sorted { $0.time < $1.time }.prefix(limit).map(\.id))
    }

    static func screenCitationCount(in minutes: StructuredMinutes?) -> Int {
        guard let minutes else { return 0 }
        var evidence: [String] = []
        evidence.append(contentsOf: minutes.issues.flatMap(\.evidence))
        evidence.append(contentsOf: minutes.requirements.flatMap(\.evidence))
        evidence.append(contentsOf: minutes.actionItems.flatMap(\.evidence))
        evidence.append(contentsOf: minutes.agreements.flatMap(\.evidence))
        evidence.append(contentsOf: minutes.afterMeeting.flatMap(\.evidence))
        evidence.append(contentsOf: minutes.uncertainties.flatMap(\.evidence))
        return Set(evidence.filter { $0.localizedCaseInsensitiveContains("屏幕") }).count
    }

    static func parseStructured(_ raw: String) -> StructuredMinutes? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            let lines = candidate.components(separatedBy: .newlines)
            candidate = lines.dropFirst().dropLast(lines.last?.hasPrefix("```") == true ? 1 : 0)
                .joined(separator: "\n")
        }
        if let first = candidate.firstIndex(of: "{"),
           let last = candidate.lastIndex(of: "}") {
            candidate = String(candidate[first...last])
        }
        guard let data = candidate.data(using: .utf8),
              var value = try? JSONDecoder().decode(StructuredMinutes.self, from: data)
        else { return nil }
        ActionTracking.normalizeModelOutput(&value)
        guard value.isMeaningful else { return nil }
        return value
    }

    // MARK: - OpenAI-compatible providers

    private func runOpenAICompatible(
        timeline: String,
        imageIDs: Set<Int>,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let client = OpenAICompatibleClient(
            baseURL: settings.providerBaseURL,
            apiKey: settings.providerKey,
            model: settings.providerModel,
            supportsVision: settings.providerSupportsVision,
            apiStyle: settings.provider.apiStyle,
            httpHeaders: settings.provider.httpHeaders
        )

        let attachments = assets.captures
            .filter { imageIDs.contains($0.id) }
            .compactMap { capture -> OpenAICompatibleClient.Attachment? in
                guard let jpeg = jpegData(from: capture.image) else { return nil }
                let reason = capture.evidenceReason.map { "；补充核对原因：\($0)" } ?? ""
                return .init(caption: "图片 #\(capture.id)（屏幕画面，时间 \(capture.timecode)\(reason)）：",
                             jpeg: jpeg)
            }

        let materialAttachments = assets.materials.compactMap { material -> OpenAICompatibleClient.Attachment? in
            guard let jpeg = material.imageJPEG else { return nil }
            return .init(caption: "会议材料图片《\(material.name)》：", jpeg: jpeg)
        }

        let startedAt = Date()
        let images = materialAttachments + attachments
        let estimatedInput = TokenEstimator.count(PromptBuilder.systemPrompt + "\n" + timeline)
            + images.count * 900
        do {
            let result = try await client.completeDetailed(
                system: PromptBuilder.systemPrompt, user: timeline,
                images: images, onProgress: progress)
            TokenUsageLedger.record(
                startedAt: startedAt, backend: settings.provider.name,
                model: settings.providerModel,
                inputTokens: result.inputTokens ?? estimatedInput,
                outputTokens: result.outputTokens ?? TokenEstimator.count(result.text),
                isEstimated: result.inputTokens == nil || result.outputTokens == nil,
                status: .succeeded)
            return result.text
        } catch {
            TokenUsageLedger.record(
                startedAt: startedAt, backend: settings.provider.name,
                model: settings.providerModel, inputTokens: estimatedInput,
                outputTokens: 0, isEstimated: true,
                status: error is CancellationError ? .cancelled : .failed, error: error)
            throw error
        }
    }

    // MARK: - Local CLI

    /// The CLI is an agentic tool, not a plain inference endpoint — it can only
    /// take text on stdin. Screen captures therefore reach it as OCR text; the
    /// diagram images are dropped. That is the tradeoff for using this backend.
    private func runLocalCLI(timeline: String, imageURLs: [URL]) async throws -> String {
        let prompt = """
        以下是会议材料，请按上述要求输出结构化 JSON。不要有任何前言、说明或追问。

        \(timeline)
        """
        return try await ModelTextClient(settings: settings).complete(
            system: PromptBuilder.systemPrompt, user: prompt, images: imageURLs)
    }

    private func jpegData(from image: CGImage, quality: CGFloat = 0.72) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    enum Failure: LocalizedError {
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "模型没有返回内容。可能是内容过长或被拒绝，可尝试关闭画面分析后重试。"
            }
        }
    }

}
