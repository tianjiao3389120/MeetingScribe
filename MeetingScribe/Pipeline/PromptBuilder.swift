import Foundation

/// Weaves the transcript and the screen captures into one time-ordered document.
///
/// This interleaving is the whole point of the app. Audio alone gives you "他
/// 说那个引擎崩溃的问题"; the frame that was on screen at that moment gives you
/// the alert count, the hostnames and the dates. Presented in timeline order,
/// the model can attribute the numbers to the right topic instead of guessing.
struct PromptBuilder {

    let assets: MeetingAssets
    let contextHint: String
    /// Frames sent as images rather than OCR text. Diagrams need pixels;
    /// dashboards read fine as text and cost a tenth as much.
    let imageCaptureIDs: Set<Int>

    static let systemPrompt = """
    你是一位资深的技术会议记录员，服务于企业 IT / 信息安全团队。

    你会收到一份按时间轴交错排列的会议材料：`[时间]` 开头的是逐字稿，`【屏幕 时间】` \
    开头的是当时屏幕上出现的内容（来自屏幕共享的截图与文字识别）。

    要求：

    1. **屏幕内容是事实来源。** 逐字稿由语音识别生成，人名、编号、版本号、日期经常出错；\
    屏幕上的文字是准确的。两者冲突时以屏幕为准，并在纪要中使用屏幕上的准确写法。
    2. **语音识别错误请依据上下文纠正**，不要照抄明显不通的词。技术术语尤其容易出错。
    3. **优先提取可核查的事实**：数字、日期、版本号、主机名、责任人、交付时间。\
    宁可写「约 680 万条」也不要写「很多数据」。
    4. **区分已确认与推测**。会上说「我们推测」「可能」的，不要写成结论。
    5. **识别会议边界**。寒暄、等人、以及会议结束后仍被录到的内容不属于纪要，\
    如果发现这类内容，请单独归入「会后（非正式内容）」一节并提醒用户。
    6. **协作约定必须逐条保留，不要因为"零碎"或"像闲聊"而省略。** 抄送名单、\
    联系人与升级路径、发送前后的确认动作、材料交付方式与渠道 —— 这类内容往往夹在\
    正事之间用一句话带过，但它们是下次执行时真正会用到的东西。带上具体细节\
    （抄给谁、找谁、走哪个渠道），不要概括成「注意邮件沟通」这种没法执行的话。\
    只要发生在会议进行中，就归入正式待办，不要因为靠近结尾而误判为会后闲谈。
    7. 待办事项必须写明**责任方**。责任方不明确时标注「待明确」，不要臆造。
    8. 不确定的人名、术语，在其后标注〔音〕。
    9. **全文不要使用 emoji 或任何图标符号。** 状态一律用方括号文字标注，\
    提醒用「注意：」开头的普通句子，不要用 ⚠️ ✅ 🔴 等符号。
    10. **若材料带有【说话人X】标记**，用它来判断责任归属：谁在汇报、谁在提要求、\
    谁做出承诺。标记只表示「不同的人」，不含身份信息 —— 请结合发言内容推断各自\
    角色（如「厂商工程师」「客户方」），并在纪要开头用一两句说明你的判断依据。\
    若某人自报姓名或被他人称呼，可将姓名与说话人对应起来并标注〔音〕。\
    分离结果可能有误，遇到与内容明显矛盾处以内容为准。

    输出 Markdown，结构如下（没有内容的小节可以省略）：

    ```
    # 会议纪要

    **性质** / **时长** / **议程**

    ## 一、问题与进展
    每项：标题 + 状态标记（[已闭环] / [待更新] / [进行中] / [等待中]）+ 根因 + 方案 + 现状

    ## 二、需求
    表格：需求 | 状态 | 时程

    ## 三、待办事项
    按责任方分组的 checkbox 列表；末尾单列「协作约定」一组，
    收录抄送、联系人、渠道、确认动作等执行细节

    ## 四、会后（非正式内容）
    仅在检测到时出现

    > 末尾用引用块列出需要人工核对的存疑项
    ```
    """

    /// Rough ceiling on the assembled timeline, in characters.
    ///
    /// The smallest context window among the supported providers is around
    /// 32k tokens; Chinese runs close to one token per character, so this
    /// leaves room for the system prompt and the response. A three-hour
    /// meeting exceeds it, and blowing the limit surfaces as an empty reply or
    /// an opaque vendor error — worse than degrading deliberately.
    static let characterBudget = 45_000

    /// True when the assembled timeline had to be trimmed to fit.
    private(set) var didTrim = false

    /// The user-turn text. Image captures are attached separately by the backend.
    func buildTimeline() -> String {
        let full = assembleTimeline(includingScreenText: true)
        guard full.count > Self.characterBudget else { return full }

        // Screen OCR is the first thing to go: dashboards and alert lists are
        // verbose, and the transcript is what carries the discussion.
        let withoutScreen = assembleTimeline(includingScreenText: false)
        if withoutScreen.count <= Self.characterBudget {
            return withoutScreen + "\n\n（注：会议较长，屏幕文字内容已省略以适应模型上下文限制。）"
        }

        // Still too long — keep the head and tail of the transcript, which hold
        // the agenda and the conclusions, and say plainly what was dropped.
        return trimmedToBudget(withoutScreen)
    }

    private func trimmedToBudget(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var head: [String] = []
        var tail: [String] = []
        var headSize = 0, tailSize = 0
        let half = Self.characterBudget / 2

        var front = 0, back = lines.count - 1
        while front <= back {
            if headSize <= tailSize {
                let line = lines[front]
                if headSize + line.count > half { break }
                head.append(line); headSize += line.count + 1; front += 1
            } else {
                let line = lines[back]
                if tailSize + line.count > half { break }
                tail.insert(line, at: 0); tailSize += line.count + 1; back -= 1
            }
        }

        let dropped = lines.count - head.count - tail.count
        return head.joined(separator: "\n")
            + "\n\n〔中间约 \(dropped) 行因长度限制未包含，请在纪要中说明本次材料不完整〕\n\n"
            + tail.joined(separator: "\n")
    }

    private func assembleTimeline(includingScreenText: Bool) -> String {
        var lines: [String] = []

        lines.append("会议文件：\(assets.title)")
        lines.append("时长：\(TranscriptSegment.humanDuration(assets.duration))")
        if !contextHint.isEmpty {
            lines.append("背景信息：\(contextHint)")
        }
        if assets.hasVideo {
            lines.append("含屏幕录像，已提取 \(assets.captures.count) 个画面。")
        }
        if let diarization = assets.diarization {
            let shares = diarization.ranking.prefix(6).map { entry -> String in
                let label = diarization.labels[entry.speaker] ?? "\(entry.speaker)"
                let total = diarization.segments.reduce(0.0) { $0 + ($1.end - $1.start) }
                return "说话人\(label) \(Int(entry.seconds / max(total, 1) * 100))%"
            }
            lines.append("已做说话人分离，识别出 \(diarization.speakerCount) 位说话人"
                         + "（发言占比：\(shares.joined(separator: "、"))）。")
        }
        lines.append("")
        lines.append("---")
        lines.append("")

        // Merge both streams into one chronological sequence.
        enum Entry {
            case speech(TranscriptSegment)
            case screen(ScreenCapture)

            var time: TimeInterval {
                switch self {
                case .speech(let s): return s.start
                case .screen(let c): return c.time
                }
            }
        }

        var entries: [Entry] = assets.transcript.segments.map(Entry.speech)
        entries += assets.captures.map(Entry.screen)
        entries.sort { $0.time < $1.time }

        var lastSpeaker: Int?

        for entry in entries {
            switch entry {
            case .speech(let segment):
                // Only mark the line when the speaker changes — repeating the
                // tag on every line buries the transcript in labels.
                if let diarization = assets.diarization,
                   let speaker = diarization.speaker(from: segment.start, to: segment.end) {
                    let label = diarization.labels[speaker] ?? "\(speaker)"
                    if speaker != lastSpeaker {
                        lines.append("")
                        lines.append("[\(segment.timecode)] 【说话人\(label)】\(segment.text)")
                        lastSpeaker = speaker
                    } else {
                        lines.append("[\(segment.timecode)] \(segment.text)")
                    }
                } else {
                    lines.append("[\(segment.timecode)] \(segment.text)")
                }

            case .screen(let capture):
                let held = capture.duration >= 20
                    ? "，停留 \(Int(capture.duration)) 秒"
                    : ""
                if imageCaptureIDs.contains(capture.id) {
                    lines.append("")
                    lines.append("【屏幕 \(capture.timecode)\(held)】见随附图片 #\(capture.id)")
                    lines.append("")
                } else if includingScreenText, !capture.recognizedText.isEmpty {
                    lines.append("")
                    lines.append("【屏幕 \(capture.timecode)\(held)】")
                    lines.append("```")
                    lines.append(capture.textBlock)
                    lines.append("```")
                    lines.append("")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Picks which captures are worth sending as images.
    ///
    /// A frame with little recognised text is probably a diagram — an
    /// architecture drawing or a chart — where the layout carries the meaning
    /// and OCR gives you a bag of disconnected labels. Those go as images.
    /// Text-heavy frames go as OCR text.
    static func selectImageCaptures(from captures: [ScreenCapture], limit: Int) -> Set<Int> {
        let diagrams = captures
            .filter { !$0.isTextDominant && !$0.recognizedText.isEmpty }
            .sorted { $0.duration > $1.duration }
            .prefix(limit)
        return Set(diagrams.map(\.id))
    }
}
