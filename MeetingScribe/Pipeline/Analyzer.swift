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

    /// Builds the same text and image selection used by `run`, without invoking a model.
    /// Keeping this here makes the user-visible preview an exact representation of the request.
    func requestPreview() -> String {
        let prepared = prepareRequest()
        let images = prepared.imageIDs.isEmpty
            ? "无"
            : prepared.imageIDs.sorted().map(String.init).joined(separator: "、")
        return """
        ===== 系统提示词 =====
        \(PromptBuilder.systemPrompt)

        ===== 用户提交内容 =====
        \(prepared.timeline)

        ===== 随请求发送的画面编号 =====
        \(images)
        """
    }

    private func prepareRequest() -> (modelAssets: MeetingAssets, imageIDs: Set<Int>, timeline: String) {
        let selectedAdaptiveIDs = Self.selectAdaptiveOCRCaptures(
            from: assets.captures, limit: 6)
        var modelAssets = assets
        modelAssets.captures = assets.captures.filter {
            $0.evidenceReason == nil || selectedAdaptiveIDs.contains($0.id)
        }
        let canSendImages: Bool
        switch settings.backend {
        case .codexCLI: canSendImages = false
        case .claudeCLI: canSendImages = false
        case .openAICompatible: canSendImages = settings.providerSupportsVision
        }
        let imageIDs = canSendImages
            ? PromptBuilder.selectImageCaptures(from: modelAssets.captures, limit: 12)
            : []
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
        let imageIDs = prepared.imageIDs
        let timeline = prepared.timeline

        let raw: String
        switch settings.backend {
        case .codexCLI:
            progress("正在通过本机 Codex CLI 生成纪要…")
            raw = try await runLocalCLI(timeline: timeline)
        case .claudeCLI:
            progress("正在通过本机 Claude Code 生成纪要…")
            raw = try await runLocalCLI(timeline: timeline)
        case .openAICompatible:
            let preset = settings.provider
            progress("正在调用 \(preset.name)（\(settings.providerModel)）生成纪要…")
            raw = try await runOpenAICompatible(timeline: timeline,
                                                imageIDs: imageIDs,
                                                progress: progress)
        }

        var phases = [GenerationUsage.estimatedPhase(
            name: "主纪要", input: PromptBuilder.systemPrompt + "\n" + timeline, output: raw)]
        if let structured = Self.parseStructured(raw) {
            let (reviewed, repairUsage) = await repairScreenEvidenceIfNeeded(
                structured, progress: progress)
            if let repairUsage { phases.append(repairUsage) }
            return Result(markdown: StructuredMinutesRenderer.markdown(from: reviewed),
                          structured: reviewed, usedFallback: false,
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
        case .codexCLI, .claudeCLI:
            return Set(adaptive.filter { !$0.recognizedText.isEmpty }.map(\.id))
        case .openAICompatible:
            guard settings.providerSupportsVision else {
                return Set(adaptive.filter { !$0.recognizedText.isEmpty }.map(\.id))
            }
            let imageIDs = PromptBuilder.selectImageCaptures(from: assets.captures, limit: 12)
            return Set(adaptive.filter {
                imageIDs.contains($0.id) || !$0.recognizedText.isEmpty
            }.map(\.id))
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
            guard !selected.contains(where: { abs($0.time - capture.time) < 8 }) else { continue }
            selected.append(capture)
            if selected.count == limit { break }
        }
        return Set(selected.map(\.id))
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

    static func shouldRepairScreenEvidence(minutes: StructuredMinutes,
                                           assets: MeetingAssets,
                                           settings: Settings) -> Bool {
        !screenFramesSentToModel(assets: assets, settings: settings).isEmpty
            && screenCitationCount(in: minutes) == 0
    }

    /// A cheap second pass used only when adaptive OCR reached the model but
    /// none of it survived into evidence fields. It cannot make the primary
    /// analysis fail and never repeats transcription, extraction, or OCR.
    private func repairScreenEvidenceIfNeeded(
        _ minutes: StructuredMinutes,
        progress: @escaping @Sendable (String) -> Void
    ) async -> (StructuredMinutes, GenerationUsage.Phase?) {
        guard Self.shouldRepairScreenEvidence(minutes: minutes,
                                              assets: assets,
                                              settings: settings) else { return (minutes, nil) }
        let sentIDs = Self.screenFramesSentToModel(assets: assets, settings: settings)
        let evidence = assets.captures
            .filter { sentIDs.contains($0.id) && !$0.recognizedText.isEmpty }
            .sorted { $0.time < $1.time }
            .map { capture in
                let reason = capture.evidenceReason ?? "核对逐字稿疑点"
                let text = String(capture.textBlock.prefix(1_500))
                return "【屏幕 \(capture.timecode)，核对原因：\(reason)】\n\(text)"
            }
            .joined(separator: "\n\n")
        guard !evidence.isEmpty,
              let encoded = try? JSONEncoder().encode(minutes),
              let minutesJSON = String(data: encoded, encoding: .utf8) else { return (minutes, nil) }

        progress("补充画面已送达但未被引用，正在校验证据…")
        do {
            let system = "你负责校验会议纪要中的屏幕证据。只输出完整合法 JSON，不要解释。"
            let user = """
                对照补充屏幕OCR，修订下面的结构化纪要：
                1. 只在OCR确实支持、纠正或补充某条事实时修改该条，并在 evidence 加入 `屏幕 MM:SS`。
                2. 屏幕与逐字稿冲突时，以屏幕文字为准；可纠正名称、数字、日期、版本、报错和配置项。
                3. OCR没有提供有效新事实时保持原文，不得为了产生引用而牵强引用或删除不确定项。
                4. 保留原JSON全部字段和无关内容，不要新增结构外字段。

                初版纪要JSON：
                \(minutesJSON)

                补充屏幕OCR：
                \(String(evidence.prefix(14_000)))
                """
            let context = (TokenUsageContext.current ?? TokenUsageContext(feature: "画面证据修复"))
                .replacingFeature("画面证据修复")
            let raw = try await TokenUsageContext.$current.withValue(context) {
                try await ModelTextClient(settings: settings).complete(
                    system: system, user: user, timeout: 300)
            }
            return (Self.parseStructured(raw) ?? minutes,
                    GenerationUsage.estimatedPhase(name: "画面证据修复",
                                                   input: system + "\n" + user, output: raw))
        } catch {
            return (minutes, nil)
        }
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
    private func runLocalCLI(timeline: String) async throws -> String {
        let prompt = """
        以下是会议材料，请按上述要求输出结构化 JSON。不要有任何前言、说明或追问。

        \(timeline)
        """
        return try await ModelTextClient(settings: settings).complete(
            system: PromptBuilder.systemPrompt, user: prompt)
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
